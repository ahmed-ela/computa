import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class ChatGPTInferenceCookieStoreTests: XCTestCase {
    private let conversation = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    private func cookie(_ name: String = "session_fixture", domain: String = "chatgpt.com", path: String = "/",
                        value: String = "PRIVATE_SYNTHETIC_VALUE", expiry: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path,
            .secure: "TRUE", .init(rawValue: "HttpOnly"): "TRUE"]
        if let expiry { properties[.expires] = expiry }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }

    func testPolicyExcludesPairedAndUnpairedCanonicalRootConversationFamiliesOnly() throws {
        let cookies = try [cookie(), cookie("conv_key_" + conversation), cookie("history_off_" + conversation, value: "0"),
            cookie("conv_key_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"), cookie("conv_key_not-a-uuid"),
            cookie("conv_key_" + conversation.uppercased()), cookie("conv_key_" + conversation, path: "/auth"),
            cookie("history_off_" + conversation, domain: "auth.chatgpt.com")]
        let selected = try ChatGPTInferenceCookieSeed.select(cookies, now: Date())
        XCTAssertEqual(selected.eligibleCookieCount, 8)
        XCTAssertEqual(selected.excludedConversationCookieCount, 3)
        XCTAssertEqual(selected.cookies.count, 5)
        XCTAssertTrue(zip(selected.cookies, [cookies[0], cookies[4], cookies[5], cookies[6], cookies[7]]).allSatisfy { $0 === $1 })
    }

    func testPolicyUsesOnlyStrictChatGPTDomainsAndKeepsCookieAttributesAndPaths() throws {
        let cookies = try [cookie(domain: ".chatgpt.com", path: "/auth"), cookie(domain: "auth.chatgpt.com"),
            cookie(domain: ".other.chatgpt.com"), cookie(domain: "google.com"), cookie(domain: "openai.com"),
            cookie(domain: "chatgpt.com.evil.test"), cookie(domain: "evilchatgpt.com")]
        let selection = try ChatGPTInferenceCookieSeed.select(cookies, now: Date())
        XCTAssertEqual(selection.cookies.count, 3)
        for (actual, expected) in zip(selection.cookies, cookies.prefix(3)) {
            XCTAssertTrue(actual === expected)
            XCTAssertEqual(actual.properties as NSDictionary?, expected.properties as NSDictionary?)
        }
    }

    func testPolicySkipsExpiredCookiesAndRejectsDuplicateOrOverBoundSources() throws {
        let now = Date()
        XCTAssertTrue(try ChatGPTInferenceCookieSeed.select([cookie(expiry: now.addingTimeInterval(-1))], now: now).cookies.isEmpty)
        let one = try cookie()
        XCTAssertThrowsError(try ChatGPTInferenceCookieSeed.select([one, one], now: now))
        XCTAssertThrowsError(try ChatGPTInferenceCookieSeed.select(Array(repeating: one, count: 4_097), now: now))
        let tooMany = try (0..<513).map { try cookie("fixture_\($0)") }
        XCTAssertThrowsError(try ChatGPTInferenceCookieSeed.select(tooMany, now: now))
        XCTAssertThrowsError(try ChatGPTInferenceCookieSeed.select([], now: Date(timeIntervalSince1970: .nan)))
    }

    func testSeedCopiesOriginalObjectsVerifiesDestinationAndNeverWritesSource() async throws {
        let auth = try cookie(), key = try cookie("conv_key_" + conversation), marker = try cookie("history_off_" + conversation)
        let source = CookieSeedStore([auth, key, marker, try cookie(domain: "google.com")])
        let destination = CookieSeedStore()
        let seed = ChatGPTInferenceCookieSeed(source: source, destination: destination)
        var drained = false
        try await seed.run(until: .now + .seconds(2), isCurrent: { true }, onDrained: { drained = true })
        XCTAssertTrue(drained)
        XCTAssertEqual(source.cookies.count, 4); XCTAssertTrue(source.sets.isEmpty)
        XCTAssertEqual(destination.sets.count, 1); XCTAssertTrue(destination.sets.first === auth)
        XCTAssertEqual(seed.verifiedSummary, .init(sourceCookieCount: 4, eligibleCookieCount: 3,
            excludedConversationCookieCount: 2, seededCookieCount: 1,
            estimatedCookieHeaderUTF8Bytes: ChatGPTProfileCookieBudget.estimate(cookies: [auth])?.estimatedCookieHeaderUTF8Bytes))
        XCTAssertTrue(Mirror(reflecting: try XCTUnwrap(seed.verifiedSummary)).children.allSatisfy { $0.value is Int || $0.value is Int? })
    }

    func testSeedRejectsNonemptyDestinationWithoutWritingEitherStore() async throws {
        let source = CookieSeedStore([try cookie()]), destination = CookieSeedStore([try cookie("unexpected")])
        let seed = ChatGPTInferenceCookieSeed(source: source, destination: destination)
        do { try await seed.run(until: .now + .seconds(2), isCurrent: { true }, onDrained: {}); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? ChatGPTInferenceCookieSeed.Failure, .destinationNotEmpty) }
        XCTAssertTrue(source.sets.isEmpty); XCTAssertTrue(destination.sets.isEmpty); XCTAssertNil(seed.verifiedSummary)
    }

    func testSeedFailureAndWrongViewStoreCannotPublishOrFallBackToTheHumanProfile() async throws {
        for failsSeeding in [false, true] {
            let browser = EmbeddedBrowserSession(persistent: false)
            defer { browser.shutdown() }
            let humanID = try browser.createTab(), human = try XCTUnwrap(browser.webView(for: humanID))
            let source = CookieSeedStore(failsSeeding ? [try cookie()] : []), destination = CookieSeedStore()
            destination.dropWrites = failsSeeding
            browser.setCookieSeedFactoryForTesting { _, _ in ChatGPTInferenceCookieSeed(source: source, destination: destination) }
            var createdViews = 0, loads = 0
            browser.setModelViewFactoryForTesting { _ in
                createdViews += 1
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = human.configuration.websiteDataStore
                let view = CookieSeedNoNavigationView(frame: .zero, configuration: configuration)
                view.onLoad = { loads += 1 }
                return view
            }
            let transport = EmbeddedWebModelTransport(browser: browser)
            do { _ = try await start(transport); XCTFail("Expected failed private-profile Start") }
            catch { XCTAssertEqual(error as? ChatGPTInferenceCookieSeed.Failure, .verificationFailed) }
            XCTAssertEqual(browser.tabs.map(\.id), [humanID]); XCTAssertEqual(browser.selectedTabID, humanID)
            XCTAssertTrue(browser.webView(for: humanID) === human)
            XCTAssertEqual(createdViews, failsSeeding ? 0 : 1); XCTAssertEqual(loads, 0)
            XCTAssertEqual(browser.pendingInferenceCookieSeedsForTesting, 0); XCTAssertTrue(source.sets.isEmpty)
        }
    }

    func testReadbackMismatchCannotPublishASeedProof() async throws {
        let source = CookieSeedStore([try cookie()]), destination = CookieSeedStore()
        destination.dropWrites = true
        let seed = ChatGPTInferenceCookieSeed(source: source, destination: destination)
        do { try await seed.run(until: .now + .seconds(2), isCurrent: { true }, onDrained: {}); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? ChatGPTInferenceCookieSeed.Failure, .verificationFailed) }
        XCTAssertNil(seed.verifiedSummary); XCTAssertTrue(source.sets.isEmpty)
    }

    func testReadbackRejectsChangedAuthenticationAndPolicyAttributes() async throws {
        let original = try cookie(expiry: Date().addingTimeInterval(3_600))
        let changes: [(HTTPCookiePropertyKey, Any?)] = [(.name, "changed"), (.value, "changed"), (.domain, "other.chatgpt.com"),
            (.path, "/auth"), (.secure, nil), (.init(rawValue: "HttpOnly"), nil),
            (.expires, Date().addingTimeInterval(7_200)), (.expires, nil), (.sameSitePolicy, "strict")]
        for (key, value) in changes {
            let source = CookieSeedStore([original]), destination = CookieSeedStore()
            var properties = try XCTUnwrap(original.properties)
            properties[key] = value
            let changed = try XCTUnwrap(HTTPCookie(properties: properties))
            destination.writeTransform = { _ in changed }
            let seed = ChatGPTInferenceCookieSeed(source: source, destination: destination)
            do { try await seed.run(until: .now + .seconds(2), isCurrent: { true }, onDrained: {}); XCTFail("Accepted changed cookie attribute") }
            catch { XCTAssertEqual(error as? ChatGPTInferenceCookieSeed.Failure, .verificationFailed) }
            XCTAssertNil(seed.verifiedSummary); XCTAssertTrue(source.sets.isEmpty)
        }
    }

    func testSavedVerificationGatePreventsCookieSeeding() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        var factories = 0
        browser.setCookieSeedFactoryForTesting { _, _ in
            factories += 1
            return ChatGPTInferenceCookieSeed(source: CookieSeedStore(), destination: CookieSeedStore())
        }
        browser.recordHumanVerificationRequired(provider: "chatgpt")
        let transport = EmbeddedWebModelTransport(browser: browser)
        do { _ = try await start(transport); XCTFail("Expected saved verification gate") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.chatgpt)) }
        XCTAssertEqual(factories, 0); XCTAssertTrue(browser.tabs.isEmpty)
    }

    func testGateArrivingDuringSeedingClosesOnlyTheUnpublishedInferenceView() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        let human = try browser.createTab()
        var loads = 0
        browser.setModelViewFactoryForTesting {
            let view = CookieSeedNoNavigationView(frame: .zero, configuration: $0)
            view.onLoad = { loads += 1 }
            return view
        }
        let source = CookieSeedStore(), destination = CookieSeedStore(); source.holdReads = true
        browser.setCookieSeedFactoryForTesting { _, _ in ChatGPTInferenceCookieSeed(source: source, destination: destination) }
        let transport = EmbeddedWebModelTransport(browser: browser)
        let task = Task { try await start(transport) }
        await yieldUntil { source.pendingReads.count == 1 }
        browser.recordHumanVerificationRequired(provider: "chatgpt")
        source.releaseRead()
        do { _ = try await task.value; XCTFail("Expected verification gate") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.chatgpt)) }
        XCTAssertEqual(browser.tabs.map(\.id), [human]); XCTAssertTrue(source.sets.isEmpty)
        XCTAssertEqual(loads, 0, "A new verification block must prevent even the initial provider navigation")
    }

    func testTransportCapacityRetainsTimedOutCallerReservationsUntilCallbacksDrain() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        var sources: [CookieSeedStore] = []
        browser.setCookieSeedFactoryForTesting { _, _ in
            let source = CookieSeedStore(); source.holdReads = true; sources.append(source)
            return ChatGPTInferenceCookieSeed(source: source, destination: CookieSeedStore())
        }
        let transport = EmbeddedWebModelTransport(browser: browser)
        let tasks = (0..<4).map { _ in Task { try await start(transport) } }
        await yieldUntil { sources.count == 4 && browser.pendingChatGPTInferenceCookiePreparationCount == 4 }
        for task in tasks { task.cancel() }
        for task in tasks { do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) } }
        do { _ = try await start(transport); XCTFail("Expected retained capacity") }
        catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .capacity) }
        XCTAssertEqual(sources.count, 4); XCTAssertTrue(browser.tabs.isEmpty)
        for source in sources { source.releaseRead() }
        XCTAssertEqual(browser.pendingChatGPTInferenceCookiePreparationCount, 0)
    }

    func testSuccessfulSeedAwaitingAdoptionStillCountsBesideFailedPendingCallbacks() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        browser.setModelViewFactoryForTesting { CookieSeedNoNavigationView(frame: .zero, configuration: $0) }
        var sources: [CookieSeedStore] = []
        browser.setCookieSeedFactoryForTesting { _, _ in
            let source = CookieSeedStore(); source.holdReads = sources.count < 3; sources.append(source)
            return ChatGPTInferenceCookieSeed(source: source, destination: CookieSeedStore())
        }
        let transport = EmbeddedWebModelTransport(browser: browser)
        let tasks = (0..<3).map { _ in Task { try await start(transport) } }
        await yieldUntil { sources.count == 3 }
        for task in tasks { task.cancel() }
        for task in tasks { do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) } }
        var checkedGap = false
        browser.setAfterCookieSeedForTesting {
            browser.setAfterCookieSeedForTesting(nil)
            checkedGap = true
            do { _ = try await self.start(transport); XCTFail("A fifth resource was admitted before the successful fourth Start adopted its view") }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .capacity) }
        }
        _ = try await start(transport)
        XCTAssertTrue(checkedGap); XCTAssertEqual(sources.count, 4)
        for source in sources.prefix(3) { source.releaseRead() }
    }

    private func start(_ transport: EmbeddedWebModelTransport) async throws -> Data {
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")
        return try await transport.request(operation: "webProviderStart", params: JSONSerialization.data(withJSONObject: [
            "provider": "chatgpt", "modelChoice": try XCTUnwrap(choice.canonicalJSONString),
        ]))
    }

    func testDeadlineRetainsIssuedReadUntilItReturnsAndNeverChainsAfterward() async throws {
        let source = CookieSeedStore([try cookie()]), destination = CookieSeedStore()
        source.holdReads = true
        let seed = ChatGPTInferenceCookieSeed(source: source, destination: destination)
        var drained = false
        do { try await seed.run(until: .now + .milliseconds(20), isCurrent: { true }, onDrained: { drained = true }); XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? ChatGPTInferenceCookieSeed.Failure, .deadline) }
        XCTAssertFalse(drained); XCTAssertEqual(source.pendingReads.count, 1)
        source.releaseRead(twice: true)
        XCTAssertTrue(drained); XCTAssertEqual(destination.reads, 0); XCTAssertTrue(destination.sets.isEmpty)
    }

    func testDeadlineCrossingDuringSourceSelectionCannotIssueDestinationRead() async throws {
        let slow = try XCTUnwrap(DeadlineCookie(properties: cookie().properties!))
        slow.armDelay()
        let source = CookieSeedStore([slow]), destination = CookieSeedStore()
        let seed = ChatGPTInferenceCookieSeed(source: source, destination: destination)
        do { try await seed.run(until: .now + .milliseconds(20), isCurrent: { true }, onDrained: {}); XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? ChatGPTInferenceCookieSeed.Failure, .deadline) }
        XCTAssertEqual(destination.reads, 0, "Selection must recheck before dispatching another store operation")
        XCTAssertNil(seed.verifiedSummary)
    }

    func testDeadlineCrossingDuringReadbackCannotPublishSuccess() async throws {
        let original = try cookie(), slow = try XCTUnwrap(DeadlineCookie(properties: cookie().properties!))
        slow.armDelay()
        let source = CookieSeedStore([original]), destination = CookieSeedStore()
        destination.writeTransform = { _ in slow }
        let seed = ChatGPTInferenceCookieSeed(source: source, destination: destination)
        do { try await seed.run(until: .now + .milliseconds(20), isCurrent: { true }, onDrained: {}); XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? ChatGPTInferenceCookieSeed.Failure, .deadline) }
        XCTAssertNil(seed.verifiedSummary, "Readback cannot outlive its admission deadline")
    }

    func testCancellationRetainsIssuedWriteAndStopsBeforeTheNextCookie() async throws {
        let source = CookieSeedStore([try cookie("first"), try cookie("second")]), destination = CookieSeedStore()
        destination.holdSets = true
        let seed = ChatGPTInferenceCookieSeed(source: source, destination: destination)
        var drained = false
        let task = Task { try await seed.run(until: .now + .seconds(2), isCurrent: { true }, onDrained: { drained = true }) }
        await yieldUntil { destination.pendingSets.count == 1 }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(drained); XCTAssertEqual(destination.sets.count, 1)
        destination.releaseSet(twice: true)
        XCTAssertTrue(drained); XCTAssertEqual(destination.sets.count, 1)
        XCTAssertTrue(source.sets.isEmpty); XCTAssertNil(seed.verifiedSummary)
    }

    func testInvalidContextAndDuplicateCallbacksCannotDispatchAnotherOperation() async throws {
        let source = CookieSeedStore([try cookie()]), destination = CookieSeedStore()
        source.holdReads = true
        let seed = ChatGPTInferenceCookieSeed(source: source, destination: destination)
        var current = true, drained = false
        let task = Task { try await seed.run(until: .now + .seconds(2), isCurrent: { current }, onDrained: { drained = true }) }
        await yieldUntil { source.pendingReads.count == 1 }
        current = false; source.releaseRead(twice: true)
        do { try await task.value; XCTFail("Expected context rejection") } catch { XCTAssertEqual(error as? ChatGPTInferenceCookieSeed.Failure, .unavailable) }
        XCTAssertTrue(drained); XCTAssertEqual(destination.reads, 0); XCTAssertTrue(destination.sets.isEmpty)
    }

    func testFactoryReservationSurvivesCancellationAndBlocksTabAndMaintenanceAdmission() async throws {
        let browser = EmbeddedBrowserSession(persistent: false, maximumTabs: 1)
        defer { browser.shutdown() }
        let source = CookieSeedStore(), destination = CookieSeedStore(); source.holdReads = true
        browser.setCookieSeedFactoryForTesting { _, _ in ChatGPTInferenceCookieSeed(source: source, destination: destination) }
        let task = Task { try await browser.createChatGPTInferenceTab(admit: {}) }
        await yieldUntil { source.pendingReads.count == 1 }
        XCTAssertEqual(browser.pendingInferenceCookieSeedsForTesting, 1); XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertThrowsError(try browser.createTab())
        let maintenance = await browser.withExclusiveCookieMaintenance { _, _, _ in true }
        XCTAssertNil(maintenance)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(browser.pendingInferenceCookieSeedsForTesting, 1)
        XCTAssertThrowsError(try browser.createTab())
        source.releaseRead()
        XCTAssertEqual(browser.pendingInferenceCookieSeedsForTesting, 0); XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertNoThrow(try browser.createTab())
    }

    func testShutdownCancelsSeedWithoutPublishingOrReleasingAnIssuedCallback() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        let source = CookieSeedStore(), destination = CookieSeedStore(); source.holdReads = true
        browser.setCookieSeedFactoryForTesting { _, _ in ChatGPTInferenceCookieSeed(source: source, destination: destination) }
        let task = Task { try await browser.createChatGPTInferenceTab(admit: {}) }
        await yieldUntil { source.pendingReads.count == 1 }
        browser.shutdown()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(browser.pendingInferenceCookieSeedsForTesting, 1)
        source.releaseRead()
        XCTAssertEqual(browser.pendingInferenceCookieSeedsForTesting, 0); XCTAssertTrue(browser.tabs.isEmpty)
        do { _ = try await browser.createChatGPTInferenceTab(admit: {}); XCTFail("Expected closed browser") }
        catch { XCTAssertEqual(error as? EmbeddedBrowserSession.Failure, .sessionClosed) }
    }

    private func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 { if condition() { return }; await Task.yield() }
        XCTFail("The callback was not issued")
    }

    private func prewarmBrowser(source: CookieSeedStore, destination: CookieSeedStore, maximumTabs: Int = 8,
                                onLoad: (() -> Void)? = nil,
                                configureView: ((CookieSeedNoNavigationView) -> Void)? = nil) -> EmbeddedBrowserSession {
        let browser = EmbeddedBrowserSession(persistent: false, maximumTabs: maximumTabs)
        browser.setCookieSeedFactoryForTesting { _, _ in ChatGPTInferenceCookieSeed(source: source, destination: destination) }
        browser.setCookieValidationSourceForTesting { _ in source }
        browser.setModelViewFactoryForTesting { configuration in
            let view = CookieSeedNoNavigationView(frame: .zero, configuration: configuration)
            // Cookie/capacity tests represent a published root, independently
            // of the transport tests' real local document/model proofs.
            view.publishesRequestedURL = true
            view.onLoad = onLoad
            configureView?(view)
            return view
        }
        return browser
    }

    func testPrewarmLoadsOneHiddenIsolatedRootAndConsumesItsExactViewOnce() async throws {
        let source = CookieSeedStore([try cookie(), try cookie("conv_key_" + conversation)]), destination = CookieSeedStore()
        var loads = 0
        let browser = prewarmBrowser(source: source, destination: destination, onLoad: { loads += 1 })
        defer { browser.shutdown() }
        browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
        browser.prepareChatGPTInferencePrewarmIfNeeded()
        let prepared = await browser.awaitChatGPTInferencePrewarmForTesting()
        let id = try XCTUnwrap(prepared)
        let view = try XCTUnwrap(browser.webView(for: id))
        XCTAssertEqual(loads, 1); XCTAssertTrue(browser.humanTabs.isEmpty); XCTAssertNil(browser.selectedTabID)
        XCTAssertFalse(view.isInspectable); XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(destination.sets.count, 1); XCTAssertTrue(source.sets.isEmpty)
        let taken = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(2), admit: {})
        XCTAssertEqual(taken, id)
        XCTAssertTrue(browser.webView(for: id) === view)
        let again = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(2), admit: {})
        XCTAssertNil(again); XCTAssertEqual(loads, 1)
        XCTAssertThrowsError(try browser.modelChangeRevision(for: id), "Only the actual transport Start installs an owner")
    }

    func testIdleBlankPrewarmCannotBeClaimedBeforeOrAfterCookieValidation() async throws {
        for duringValidation in [false, true] {
            let source = CookieSeedStore(), destination = CookieSeedStore()
            var loads = 0
            let browser = prewarmBrowser(source: source, destination: destination, onLoad: { loads += 1 })
            defer { browser.shutdown() }
            browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
            let prepared = await browser.awaitChatGPTInferencePrewarmForTesting()
            let id = try XCTUnwrap(prepared)
            let view = try XCTUnwrap(browser.webView(for: id) as? CookieSeedNoNavigationView)
            let reads = source.reads
            let taken: UUID?
            if duringValidation {
                source.holdReads = true
                let task = Task { try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(2), admit: {}) }
                await yieldUntil { source.pendingReads.count == 1 }
                view.publishesRequestedURL = false
                source.releaseRead()
                taken = try await task.value
            } else {
                view.publishesRequestedURL = false
                taken = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(2), admit: {})
                XCTAssertEqual(source.reads, reads, "An idle blank page must be rejected before another cookie read")
            }
            XCTAssertNil(taken); XCTAssertNil(browser.webView(for: id))
            XCTAssertEqual(loads, 1); XCTAssertTrue(source.sets.isEmpty)
            XCTAssertEqual(browser.pendingChatGPTInferenceCookiePreparationCount, 0)
            let diagnostic = try XCTUnwrap(browser.lastInferencePrewarmUnavailableForTesting)
            XCTAssertTrue(diagnostic.hasPrefix("reason=blank_idle "))
            XCTAssertTrue(diagnostic.contains("urlPresent=false loading=false navigationPending=false"))
            XCTAssertLessThan(diagnostic.utf8.count, 512)
            let next = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(1), admit: {})
            XCTAssertNil(next); XCTAssertEqual(loads, 1, "Disposal must not retry the provider navigation")
        }
    }

    func testGenuinelyInFlightInitialNavigationRetainsItsExactWarmView() async throws {
        let browser = prewarmBrowser(source: CookieSeedStore(), destination: CookieSeedStore(), configureView: {
            $0.publishesRequestedURL = false
            $0.usesLocalNavigation = true
            $0.reportedLoading = true
        })
        defer { browser.shutdown() }
        browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
        let prepared = await browser.awaitChatGPTInferencePrewarmForTesting()
        let id = try XCTUnwrap(prepared)
        let view = try XCTUnwrap(browser.webView(for: id) as? CookieSeedNoNavigationView)
        XCTAssertNotNil(view.localNavigation, "The pending state requires a real WKNavigation token")
        XCTAssertNil(view.url); XCTAssertTrue(view.isLoading)
        let taken = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(2), admit: {})
        XCTAssertEqual(taken, id); XCTAssertTrue(browser.webView(for: id) === view)
        XCTAssertEqual(view.loadCount, 1); XCTAssertNil(browser.lastInferencePrewarmUnavailableForTesting)
    }

    func testNativeFailureBeforeWarmGenerationCaptureOrBeforeClaimDiscardsThePage() async throws {
        for beforeCapture in [false, true] {
            let source = CookieSeedStore(), destination = CookieSeedStore()
            var loads = 0
            let browser = prewarmBrowser(source: source, destination: destination, onLoad: { loads += 1 }, configureView: { view in
                if beforeCapture {
                    let loaded = view.onLoad
                    view.onLoad = { [weak view] in
                        loaded?()
                        guard let view else { return }
                        view.navigationDelegate?.webViewWebContentProcessDidTerminate?(view)
                    }
                }
            })
            defer { browser.shutdown() }
            browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
            let prepared = await browser.awaitChatGPTInferencePrewarmForTesting()
            if beforeCapture { XCTAssertNil(prepared) }
            else {
                let id = try XCTUnwrap(prepared)
                // Ordinary URL policy denial records a native page error while
                // preserving its previously published root and generation.
                XCTAssertThrowsError(try browser.navigate(tabID: id, to: URL(string: "file:///not-loaded")!))
            }
            let taken = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(2), admit: {})
            XCTAssertNil(taken); XCTAssertTrue(browser.tabs.isEmpty)
            XCTAssertEqual(loads, 1); XCTAssertTrue(source.sets.isEmpty)
            XCTAssertEqual(browser.pendingChatGPTInferenceCookiePreparationCount, 0)
            let diagnostic = try XCTUnwrap(browser.lastInferencePrewarmUnavailableForTesting)
            XCTAssertTrue(diagnostic.hasPrefix("reason=navigation_error "))
            XCTAssertTrue(diagnostic.contains("tabError=true"))
        }
    }

    func testNavigationCrossingTheCookieGateCannotReuseItsOldAdmission() async throws {
        let browser = prewarmBrowser(source: CookieSeedStore(), destination: CookieSeedStore())
        defer { browser.shutdown() }
        browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
        let prepared = await browser.awaitChatGPTInferencePrewarmForTesting()
        let id = try XCTUnwrap(prepared), view = try XCTUnwrap(browser.webView(for: id))
        let root = URL(string: "https://chatgpt.com/")!
        var crossed = false
        browser.afterChatGPTNavigationGateForTesting = {
            browser.afterChatGPTNavigationGateForTesting = nil
            crossed = true
            try? browser.navigate(tabID: id, to: root)
        }
        let admitted = await browser.admitChatGPTNavigationForTesting(tabID: id, view: view, url: root)
        XCTAssertTrue(crossed); XCTAssertFalse(admitted)
        let diagnostic = try XCTUnwrap(browser.lastChatGPTNavigationDenialForTesting)
        XCTAssertTrue(diagnostic.contains("gateChecked=true"))
        XCTAssertTrue(diagnostic.contains("entryCurrent=true pendingTargetMatches=true ticketMatches=false generationMatches=false"))
        XCTAssertLessThan(diagnostic.utf8.count, 512)
        let taken = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(2), admit: {})
        XCTAssertNil(taken); XCTAssertNil(browser.webView(for: id))
    }

    func testPrewarmClaimRejectsEligibleCookieDriftButIgnoresExcludedConversationKeys() async throws {
        for drift in ["value", "path", "conversation_only"] {
            let auth = try cookie()
            let source = CookieSeedStore([auth, try cookie("conv_key_" + conversation)]), destination = CookieSeedStore()
            let browser = prewarmBrowser(source: source, destination: destination)
            defer { browser.shutdown() }
            browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
            let prepared = await browser.awaitChatGPTInferencePrewarmForTesting()
            let id = try XCTUnwrap(prepared)
            if drift == "value" { source.cookies = [try cookie(value: "CHANGED_PRIVATE_VALUE")] }
            else if drift == "path" { source.cookies = [try cookie(path: "/auth")] }
            else { source.cookies = [auth, try cookie("history_off_" + conversation, value: "changed")] }
            let taken = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(2), admit: {})
            XCTAssertEqual(taken, drift == "conversation_only" ? id : nil, drift)
            XCTAssertEqual(browser.webView(for: id) != nil, drift == "conversation_only")
            XCTAssertTrue(source.sets.isEmpty)
        }
    }

    func testPrewarmDisableExpiryShutdownAndAdmissionLossCloseOnlyTheUnusedPage() async throws {
        for operation in ["disable", "expiry", "shutdown", "admission"] {
            let browser = prewarmBrowser(source: CookieSeedStore(), destination: CookieSeedStore())
            defer { browser.shutdown() }
            if operation == "expiry" { browser.setChatGPTInferencePrewarmLifetimeForTesting(.seconds(1)) }
            browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
            let prepared = await browser.awaitChatGPTInferencePrewarmForTesting()
            let id = try XCTUnwrap(prepared)
            if operation == "disable" { browser.setChatGPTInferencePrewarmingEnabled(false, admit: {}) }
            else if operation == "expiry" { try await Task.sleep(for: .milliseconds(1_100)) }
            else if operation == "shutdown" { browser.shutdown() }
            else {
                do {
                    _ = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(2), admit: {
                        throw EmbeddedWebModelTransport.Failure.signInRequired
                    })
                    XCTFail("A current admission failure must propagate")
                } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .signInRequired) }
            }
            XCTAssertNil(browser.webView(for: id), operation)
            XCTAssertTrue(browser.tabs.isEmpty)
            let next = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(2), admit: {})
            XCTAssertNil(next, "Expiry or disposal must not automatically refill")
        }
    }

    func testClaimWaitsForOneInFlightSeedAndConcurrentClaimCannotDuplicateIt() async throws {
        let source = CookieSeedStore(), destination = CookieSeedStore(); source.holdReads = true
        var loads = 0
        let browser = prewarmBrowser(source: source, destination: destination, onLoad: { loads += 1 })
        defer { browser.shutdown() }
        browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
        await yieldUntil { source.pendingReads.count == 1 }
        let first = Task { try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(2), admit: {}) }
        await yieldUntil { browser.chatGPTInferencePrewarmClaimedForTesting }
        let second = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(2), admit: {})
        XCTAssertNil(second); XCTAssertEqual(loads, 0)
        source.holdReads = false; source.releaseRead(twice: true)
        let claimed = try await first.value
        let id = try XCTUnwrap(claimed)
        XCTAssertNotNil(browser.webView(for: id)); XCTAssertEqual(loads, 1)
        XCTAssertEqual(browser.pendingChatGPTInferenceCookiePreparationCount, 0)
    }

    func testClaimDeadlineDuringSeedReturnsWithoutLateNavigationAndRetainsCapacityUntilDrain() async throws {
        let source = CookieSeedStore(), destination = CookieSeedStore(); source.holdReads = true
        var loads = 0
        let browser = prewarmBrowser(source: source, destination: destination, maximumTabs: 1, onLoad: { loads += 1 })
        defer { browser.shutdown() }
        browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
        await yieldUntil { source.pendingReads.count == 1 }
        let started = ContinuousClock.now
        let taken = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .milliseconds(30), admit: {})
        XCTAssertNil(taken); XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertEqual(browser.pendingChatGPTInferenceCookiePreparationCount, 1)
        XCTAssertThrowsError(try browser.createTab())
        let maintenance = await browser.withExclusiveCookieMaintenance { _, _, _ in true }
        XCTAssertNil(maintenance); XCTAssertEqual(loads, 0)
        source.releaseRead(twice: true)
        XCTAssertEqual(browser.pendingChatGPTInferenceCookiePreparationCount, 0)
        XCTAssertEqual(destination.reads, 0); XCTAssertEqual(loads, 0)
        XCTAssertNoThrow(try browser.createTab())
    }

    func testValidationDeadlineAndCallerCancellationRetainCallbackCapacityWithoutClaimingThePage() async throws {
        for cancelled in [false, true] {
            let source = CookieSeedStore(), destination = CookieSeedStore()
            let browser = prewarmBrowser(source: source, destination: destination, maximumTabs: 1)
            defer { browser.shutdown() }
            browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
            let prepared = await browser.awaitChatGPTInferencePrewarmForTesting()
            let id = try XCTUnwrap(prepared)
            source.holdReads = true
            let started = ContinuousClock.now
            let task = Task { try await browser.takePrewarmedChatGPTInferenceTab(
                until: .now + (cancelled ? .seconds(2) : .milliseconds(30)), admit: {}) }
            await yieldUntil { source.pendingReads.count == 1 }
            if cancelled { task.cancel() }
            do {
                let value = try await task.value
                XCTAssertFalse(cancelled); XCTAssertNil(value)
            } catch { XCTAssertTrue(cancelled && error is CancellationError) }
            XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
            XCTAssertNil(browser.webView(for: id))
            XCTAssertEqual(browser.pendingChatGPTInferenceCookiePreparationCount, 1)
            XCTAssertThrowsError(try browser.createTab())
            let maintenance = await browser.withExclusiveCookieMaintenance { _, _, _ in true }
            XCTAssertNil(maintenance)
            source.releaseRead(twice: true)
            XCTAssertEqual(browser.pendingChatGPTInferenceCookiePreparationCount, 0)
            XCTAssertNoThrow(try browser.createTab())
        }
    }

    func testSynchronousFinalAdmissionCannotAdoptPrewarmAfterTheCallerDeadline() async throws {
        let source = CookieSeedStore(), destination = CookieSeedStore()
        var loads = 0
        let browser = prewarmBrowser(source: source, destination: destination, onLoad: { loads += 1 })
        defer { browser.shutdown() }
        browser.setChatGPTInferencePrewarmingEnabled(true, admit: {})
        let prepared = await browser.awaitChatGPTInferencePrewarmForTesting()
        let id = try XCTUnwrap(prepared)
        var admissions = 0
        let taken = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .milliseconds(200), admit: {
            admissions += 1
            if admissions == 2 {
                // This callback is synchronous: the MainActor deadline task
                // cannot run until after the final adoption guard executes.
                Thread.sleep(forTimeInterval: 0.25)
            }
        })
        XCTAssertEqual(admissions, 2)
        XCTAssertNil(taken, "A queued timer cannot authorize adoption after the caller deadline")
        XCTAssertNil(browser.webView(for: id))
        XCTAssertEqual(loads, 1, "The discarded page must not trigger another load")
        XCTAssertEqual(browser.pendingChatGPTInferenceCookiePreparationCount, 0)
        let next = try await browser.takePrewarmedChatGPTInferenceTab(until: .now + .seconds(1), admit: {})
        XCTAssertNil(next)
    }

    func testProductionChatGPTStartUsesFreshStoreWithoutNavigatingAWebsite() async throws {
        let browser = EmbeddedBrowserSession(persistent: false)
        defer { browser.shutdown() }
        let human = try XCTUnwrap(browser.webView(for: browser.createTab()))
        let originalCookies = try [cookie(), cookie("conv_key_" + conversation), cookie("history_off_" + conversation),
                                  cookie(domain: "google.com")]
        for cookie in originalCookies {
            await withCheckedContinuation { continuation in
                human.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
            }
        }
        var configurations: [WKWebViewConfiguration] = []
        browser.setModelViewFactoryForTesting { configuration in
            configurations.append(configuration)
            return CookieSeedNoNavigationView(frame: .zero, configuration: configuration)
        }
        let transport = EmbeddedWebModelTransport(browser: browser)
        let choice = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")
        let reply = try await transport.request(operation: "webProviderStart", params: JSONSerialization.data(withJSONObject: [
            "provider": "chatgpt", "modelChoice": try XCTUnwrap(choice.canonicalJSONString),
        ]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertNotNil(object["sessionToken"] as? String)
        XCTAssertEqual(configurations.count, 1)
        let inference = try XCTUnwrap(configurations.first?.websiteDataStore)
        XCTAssertFalse(inference === human.configuration.websiteDataStore,
                       "A fresh physical tab must not inherit the accumulated human cookie store")
        XCTAssertFalse(inference.isPersistent)
        XCTAssertEqual(browser.humanTabs.count, 1)
        let seeded = await cookies(inference)
        XCTAssertEqual(seeded.count, 1)
        XCTAssertEqual(seeded.first?.name, "session_fixture")
        XCTAssertEqual(seeded.first?.value, originalCookies[0].value)
        XCTAssertEqual(seeded.first?.isSecure, true); XCTAssertEqual(seeded.first?.isHTTPOnly, true)
        let retained = await cookies(human.configuration.websiteDataStore)
        XCTAssertEqual(retained.count, 4)
        for cookie in originalCookies {
            XCTAssertTrue(retained.contains { $0.name == cookie.name && $0.domain == cookie.domain && $0.value == cookie.value })
        }
        let secondReply = try await transport.request(operation: "webProviderStart", params: JSONSerialization.data(withJSONObject: [
            "provider": "chatgpt", "modelChoice": try XCTUnwrap(choice.canonicalJSONString),
        ]))
        XCTAssertFalse(secondReply.isEmpty)
        XCTAssertEqual(configurations.count, 2)
        XCTAssertFalse(configurations[0].websiteDataStore === configurations[1].websiteDataStore)
        XCTAssertFalse(configurations[1].websiteDataStore === human.configuration.websiteDataStore)
    }

    private func cookies(_ store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
    }
}

@MainActor
private final class CookieSeedNoNavigationView: WKWebView {
    var onLoad: (() -> Void)?
    var publishesRequestedURL = false
    var usesLocalNavigation = false
    var reportedLoading: Bool?
    private var requestedURL: URL?
    private(set) var localNavigation: WKNavigation?
    private(set) var loadCount = 0
    override var url: URL? { publishesRequestedURL ? requestedURL : (usesLocalNavigation ? nil : super.url) }
    override var isLoading: Bool { reportedLoading ?? super.isLoading }
    override func load(_ request: URLRequest) -> WKNavigation? {
        loadCount += 1
        requestedURL = request.url
        onLoad?()
        if usesLocalNavigation {
            // A real local navigation supplies identity without contacting a
            // provider. Its delegate is intentionally absent in this state test.
            navigationDelegate = nil
            localNavigation = super.loadHTMLString("<p>Local navigation fixture</p>", baseURL: nil)
        }
        return localNavigation
    }
}

private final class DeadlineCookie: HTTPCookie, @unchecked Sendable {
    private let lock = NSLock()
    private var delay = false
    func armDelay() { lock.lock(); delay = true; lock.unlock() }
    override var value: String {
        lock.lock(); let sleep = delay; delay = false; lock.unlock()
        if sleep { Thread.sleep(forTimeInterval: 0.06) }
        return super.value
    }
}

@MainActor
private final class CookieSeedStore: ChatGPTInferenceCookieDestination {
    var cookies: [HTTPCookie]
    var sets: [HTTPCookie] = []
    var reads = 0
    var holdReads = false, holdSets = false, dropWrites = false
    var writeTransform: ((HTTPCookie) -> HTTPCookie)?
    var pendingReads: [@MainActor ([HTTPCookie]) -> Void] = []
    var pendingSets: [(HTTPCookie, @MainActor () -> Void)] = []
    init(_ cookies: [HTTPCookie] = []) { self.cookies = cookies }
    func read(_ completion: @escaping @MainActor ([HTTPCookie]) -> Void) {
        reads += 1
        if holdReads { pendingReads.append(completion) } else { completion(cookies) }
    }
    func set(_ cookie: HTTPCookie, completion: @escaping @MainActor () -> Void) {
        sets.append(cookie)
        if holdSets { pendingSets.append((cookie, completion)) }
        else { if !dropWrites { cookies.append(writeTransform?(cookie) ?? cookie) }; completion() }
    }
    func releaseRead(twice: Bool = false) {
        let callback = pendingReads.removeFirst(), snapshot = cookies
        callback(snapshot); if twice { callback(snapshot) }
    }
    func releaseSet(twice: Bool = false) {
        let (cookie, callback) = pendingSets.removeFirst()
        if !dropWrites { cookies.append(cookie) }
        callback(); if twice { callback() }
    }
}

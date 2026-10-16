import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor
final class EmbeddedGeminiPostBlockDiagnosticTests: XCTestCase {
    func testExplicitOffPreservesImmediateOriginalDisposal() async throws {
        #if COMPUTA_GEMINI_POST_BLOCK_DIAGNOSTIC
        let f = try await Fixture.make(enabled: false)
        #else
        let f = try await Fixture.make(enabled: nil)
        #endif
        defer { f.shutdown() }
        try await f.block()
        XCTAssertNil(f.transport.geminiPostBlockDiagnosticDeadlineForTesting(sessionToken: f.token))
        XCTAssertFalse(f.browser.hasConsumedGeminiPostBlockDiagnostic)
        XCTAssertTrue(f.records.isEmpty)
        let finished = try await f.finish()
        XCTAssertEqual(finished["cleanup"] as? String, "not_created")
        XCTAssertNil(f.browser.webView(for: f.id))
        try f.assertHumanUnchanged()
    }

    func testCleanupFirstCheckpointDoesNotReenterOrArmDiagnostic() async throws {
        let f = try await Fixture.make(window: .seconds(5))
        defer { f.shutdown() }
        // No original Poll failure: ordinary Finish first sees this settled route.
        f.settle(Fixture.checkpoint)
        let result = try await f.finish()
        XCTAssertEqual(result["cleanup"] as? String, "not_created")
        XCTAssertNil(f.browser.webView(for: f.id))
        XCTAssertFalse(f.browser.hasConsumedGeminiPostBlockDiagnostic)
        XCTAssertTrue(f.records.isEmpty)
        XCTAssertNotNil(f.browser.savedHumanVerificationCheckpointIDs["gemini"])
        do {
            _ = try await f.call("webProviderStart", ["provider": "gemini"])
            XCTFail("Ordinary cleanup still latches the saved block")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        try f.assertHumanUnchanged()
    }

    func testFailureAndGateLatchImmediatelyAndTimerClosesWithoutFinish() async throws {
        let f = try await Fixture.make(window: .seconds(1))
        defer { f.shutdown() }
        try await f.block()
        let checkpoint = try XCTUnwrap(f.browser.savedHumanVerificationCheckpointIDs["gemini"])
        XCTAssertNotNil(f.browser.webView(for: f.id))
        XCTAssertNotNil(f.transport.geminiPostBlockDiagnosticDeadlineForTesting(sessionToken: f.token))
        try await f.assertOriginalFailureAndNoInput()
        do {
            _ = try await f.call("webProviderStart", ["provider": "gemini"])
            XCTFail("The retained diagnostic is not provider admission")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        try await f.waitForPhysicalClose()
        XCTAssertEqual(f.browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
        XCTAssertEqual(f.records.last?["event"] as? String, "disposed")
        XCTAssertEqual(f.records.last?["physicallyClosed"] as? Bool, true)
        XCTAssertEqual(f.records.last?["ordinaryCleanupVerified"] as? Bool, true)
        let result = try await f.finish()
        XCTAssertEqual(result["state"] as? String, "failed", "Physical disposal cannot regrade the failed task")
        XCTAssertEqual(result["cleanup"] as? String, "not_created")
        try f.assertHumanUnchanged()
    }

    func testLaterGeminiCommitCannotRecoverOrReuseOldDisposalProof() async throws {
        let f = try await Fixture.make(window: .seconds(2))
        defer { f.shutdown() }
        try await f.block()
        let originalDeadline = try XCTUnwrap(f.transport.geminiPostBlockDiagnosticDeadlineForTesting(sessionToken: f.token))
        let checkpoint = f.browser.savedHumanVerificationCheckpointIDs["gemini"]
        XCTAssertTrue(f.transport.canDisposeUntouchedGoogleCheckpointForTesting(sessionToken: f.token))
        try await f.beginLocalNavigation(to: Fixture.gemini)
        f.settle(Fixture.gemini)
        XCTAssertFalse(f.transport.canDisposeUntouchedGoogleCheckpointForTesting(sessionToken: f.token),
                       "The existing changed-generation receipt stays rejected")
        XCTAssertEqual(f.transport.geminiPostBlockDiagnosticDeadlineForTesting(sessionToken: f.token), originalDeadline)
        try await f.assertOriginalFailureAndNoInput()
        XCTAssertEqual(f.browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
        XCTAssertEqual(f.recoveryCallbacks, 0)
        XCTAssertTrue(f.records.contains { $0["routeClass"] as? String == "provider" })
        let first = Task { @MainActor in
            try JSONSerialization.data(withJSONObject: try await f.finish())
        }
        let second = Task { @MainActor in
            try JSONSerialization.data(withJSONObject: try await f.finish())
        }
        let firstData = try await first.value, secondData = try await second.value
        let a = try XCTUnwrap(JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        let b = try XCTUnwrap(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        XCTAssertEqual(a["cleanup"] as? String, "failed")
        XCTAssertEqual(b["cleanup"] as? String, "failed")
        XCTAssertEqual(a["state"] as? String, "failed")
        XCTAssertNil(f.browser.webView(for: f.id))
        XCTAssertEqual(f.records.filter { $0["event"] as? String == "disposed" }.count, 1)
        XCTAssertEqual(f.records.last?["physicallyClosed"] as? Bool, true)
        XCTAssertEqual(f.records.last?["ordinaryCleanupVerified"] as? Bool, false)
        XCTAssertEqual(f.browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
        try f.assertHumanUnchanged()
    }

    func testOneShotAndDeadlineCannotBeRenewedByPollsOrAnotherView() async throws {
        let f = try await Fixture.make(window: .milliseconds(150))
        defer { f.shutdown() }
        try await f.block()
        let deadline = f.transport.geminiPostBlockDiagnosticDeadlineForTesting(sessionToken: f.token)
        XCTAssertFalse(f.transport.setGeminiPostBlockDiagnosticWindowForTesting(.seconds(5)))
        for _ in 0..<3 { await f.assertPollFailure(.humanVerificationRequired(.gemini)) }
        XCTAssertEqual(f.transport.geminiPostBlockDiagnosticDeadlineForTesting(sessionToken: f.token), deadline)
        do {
            _ = try f.transport.createGeminiPostBlockRoleSessionForTesting(provider: .gemini, isDiscovery: true, isRecoveryProbe: true)
            XCTFail("The fixture hook cannot bypass a saved gate either")
        } catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini)) }
        try await f.waitForPhysicalClose()
        let second = try f.browser.createUnloadedModelTabForTesting()
        let view = try XCTUnwrap(f.browser.webView(for: second))
        let owner = UUID().uuidString
        try f.browser.installModelChangeSignal(tabID: second, ownerToken: owner,
            world: .world(name: "post-block-second-local-fixture"), originHost: "gemini.google.com")
        XCTAssertNil(f.browser.beginGeminiPostBlockNativeObservation(tabID: second, view: view, ownerToken: owner) { _ in
            XCTFail("A consumed one-shot cannot be acquired by another view")
        })
        XCTAssertEqual(f.createdCount, 1, "No second provider session was created")
        f.browser.closeTab(second)
        _ = try await f.finish()
        try f.assertHumanUnchanged()
    }

    func testDiscoveryRecoveryOtherProviderAndInputHistoryNeverEnroll() async throws {
        for kind in ["discovery", "recovery", "claude", "submitted", "adapter"] {
            let f = try await Fixture.make(role: kind)
            defer { f.shutdown() }
            if kind == "submitted" || kind == "adapter" {
                f.transport.invalidateGeminiPostBlockEligibilityForTesting(sessionToken: f.token,
                    submitted: kind == "submitted", adapterDispatched: kind == "adapter")
            }
            f.settle(Fixture.checkpoint)
            await f.assertPollFailure(kind == "claude" ? .unexpectedPage(.claude) : .humanVerificationRequired(.gemini))
            XCTAssertNil(f.transport.geminiPostBlockDiagnosticDeadlineForTesting(sessionToken: f.token), kind)
            XCTAssertFalse(f.browser.hasConsumedGeminiPostBlockDiagnostic, kind)
            XCTAssertTrue(f.records.isEmpty, kind)
            try await f.assertNoAdapterOrInput()
            try f.assertHumanUnchanged()
        }
    }

    func testWrongViewOwnerDuplicateAndLateCallbacksHaveNoAuthority() async throws {
        let f = try await Fixture.make(window: .milliseconds(140))
        defer { f.shutdown() }
        XCTAssertNil(f.browser.beginGeminiPostBlockNativeObservation(tabID: f.id, view: f.humanView,
            ownerToken: f.token) { _ in XCTFail("Wrong view") })
        XCTAssertNil(f.browser.beginGeminiPostBlockNativeObservation(tabID: f.id, view: f.view,
            ownerToken: UUID().uuidString) { _ in XCTFail("Wrong owner") })
        XCTAssertFalse(f.browser.hasConsumedGeminiPostBlockDiagnostic)
        try await f.block()
        let before = f.records.count
        f.browser.emitGeminiPostBlockNativeEventForTesting(tabID: f.id, view: f.humanView, event: .changed)
        XCTAssertEqual(f.records.count, before)
        let revision = try f.browser.modelChangeRevision(for: f.id)
        f.browser.emitGeminiPostBlockNativeEventForTesting(tabID: f.id, view: f.view, event: .changed)
        let once = f.records.count
        f.browser.emitGeminiPostBlockNativeEventForTesting(tabID: f.id, view: f.view, event: .changed)
        XCTAssertEqual(f.records.count, once)
        XCTAssertEqual(try f.browser.modelChangeRevision(for: f.id), revision,
                       "Diagnostic observation cannot grant a model wake/revision")
        _ = try await f.finish()
        let final = f.records.count
        f.browser.emitGeminiPostBlockNativeEventForTesting(tabID: f.id, view: f.view, event: .committed)
        f.delegate.webView?(f.view, didFinish: f.navigation)
        XCTAssertEqual(f.records.count, final)
        try f.assertHumanUnchanged()
    }

    func testEventCapReservesOneTruthfulPhysicalDisposalRecord() async throws {
        let f = try await Fixture.make(window: .milliseconds(500))
        defer { f.shutdown() }
        try await f.block()
        let deadline = f.transport.geminiPostBlockDiagnosticDeadlineForTesting(sessionToken: f.token)
        for index in 0..<60 {
            f.view.fixtureLoading = index.isMultiple(of: 2)
            f.browser.emitGeminiPostBlockNativeEventForTesting(tabID: f.id, view: f.view, event: .changed)
        }
        XCTAssertLessThanOrEqual(f.records.count, 31)
        XCTAssertEqual(f.transport.geminiPostBlockDiagnosticDeadlineForTesting(sessionToken: f.token), deadline)
        _ = try await f.finish()
        XCTAssertLessThanOrEqual(f.records.count, 32)
        XCTAssertEqual(f.records.last?["event"] as? String, "disposed")
        XCTAssertEqual(f.records.last?["eventsTruncated"] as? Bool, true)
        XCTAssertEqual(f.records.last?["physicallyClosed"] as? Bool, true)
        let allowed = Set(["kind", "captureID", "event", "elapsedMs", "maximumMs", "exactViewPresent", "generationOrdinal",
            "routeClass", "known", "loading", "pending", "committed", "finished", "navigationError", "checkpointUnchanged",
            "adapterDispatched", "sequence", "taskFailed", "physicallyClosed", "ordinaryCleanupVerified", "eventsTruncated", "record", "disposalCause"])
        for record in f.records {
            XCTAssertTrue(Set(record.keys).isSubset(of: allowed))
            XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: record).count, 960)
            XCTAssertEqual(record["adapterDispatched"] as? Bool, false)
            XCTAssertEqual(record["sequence"] as? Int, 0)
            XCTAssertEqual(record["taskFailed"] as? Bool, true)
        }
        try f.assertHumanUnchanged()
    }

    func testCancellationShutdownAndRevocationShortenWithoutFalseClosure() async throws {
        for kind in ["cancel", "shutdown", "revoked"] {
            let f = try await Fixture.make(window: .seconds(5))
            defer { f.shutdown() }
            try await f.block()
            let checkpoint = f.browser.savedHumanVerificationCheckpointIDs["gemini"]
            let start = ContinuousClock.now
            if kind == "shutdown" { f.browser.shutdown() }
            if kind == "revoked" { f.transport.revokeGeminiPostBlockObservationForTesting(sessionToken: f.token) }
            let result = try await f.finish(cancel: true)
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
            XCTAssertEqual(result["state"] as? String, "failed")
            if kind == "revoked" {
                XCTAssertEqual(result["cleanup"] as? String, "failed")
                XCTAssertTrue(f.browser.webView(for: f.id) === f.view)
                XCTAssertEqual(f.records.last?["physicallyClosed"] as? Bool, false)
                XCTAssertEqual(f.records.last?["disposalCause"] as? String, "identity_lost")
            } else {
                XCTAssertNil(f.browser.webView(for: f.id))
                XCTAssertEqual(f.records.last?["physicallyClosed"] as? Bool, true)
            }
            XCTAssertEqual(f.browser.savedHumanVerificationCheckpointIDs["gemini"], checkpoint)
            if kind != "shutdown" { try f.assertHumanUnchanged() }
        }
    }

    @MainActor private final class NavigationView: WKWebView {
        var fixtureURL: URL?
        var fixtureLoading: Bool?
        override var url: URL? { fixtureURL ?? super.url }
        override var isLoading: Bool { fixtureLoading ?? super.isLoading }
        var nativeLoading: Bool { super.isLoading }
    }

    @MainActor private final class Fixture {
        static let gemini = URL(string: "https://gemini.google.com/app")!
        static let checkpoint = URL(string: "https://www.google.com/sorry/index")!
        static let html = """
        <!doctype html><html><body><p>Local passive-navigation fixture</p><script>
        window.fixtureInputs=0;window.fixtureClicks=0;
        document.addEventListener('input',()=>window.fixtureInputs++);
        document.addEventListener('click',()=>window.fixtureClicks++);
        window.fixtureReady=true;
        </script></body></html>
        """
        let browser = EmbeddedBrowserSession(persistent: false)
        let window: NSWindow
        let host: EmbeddedModelRenderContainer
        let humanID: UUID
        let humanView: WKWebView
        var transport: EmbeddedWebModelTransport!
        var id: UUID!
        var view: NavigationView!
        var delegate: WKNavigationDelegate!
        var navigation: WKNavigation!
        var token = ""
        var createdCount = 0
        var records: [[String: Any]] = []
        var recoveryCallbacks = 0

        init(enabled: Bool?) throws {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            host = EmbeddedModelRenderContainer(session: browser)
            host.frame = window.contentView!.bounds
            window.contentView = host
            browser.installModelRenderHost(host)
            window.orderBack(nil)
            humanID = try browser.createTab()
            humanView = try XCTUnwrap(browser.webView(for: humanID))
            transport = EmbeddedWebModelTransport(browser: browser, geminiPostBlockDiagnostic: enabled, createTabForTesting: { [unowned self] _ in
                self.id = try self.browser.createUnloadedModelTabForTesting { configuration in
                    NavigationView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
                }
                self.view = try XCTUnwrap(self.browser.webView(for: self.id) as? NavigationView)
                self.delegate = try XCTUnwrap(self.view.navigationDelegate)
                self.view.navigationDelegate = nil
                self.navigation = try XCTUnwrap(self.view.loadHTMLString(Self.html, baseURL: Self.gemini))
                self.createdCount += 1
                return self.id
            })
            transport.setGeminiPostBlockDiagnosticObserverForTesting { [weak self] in self?.records.append($0) }
            browser.onHumanVerificationRecoveryCandidate = { [weak self] _ in self?.recoveryCallbacks += 1 }
        }

        static func make(enabled: Bool? = true, window: Duration = .milliseconds(150), role: String = "normal") async throws -> Fixture {
            let f = try Fixture(enabled: enabled)
            XCTAssertTrue(f.transport.setGeminiPostBlockDiagnosticWindowForTesting(window))
            if role == "discovery" || role == "recovery" || role == "claude" {
                f.token = try f.transport.createGeminiPostBlockRoleSessionForTesting(provider: role == "claude" ? .claude : .gemini,
                    isDiscovery: role == "discovery", isRecoveryProbe: role == "recovery")
            } else {
                let start = try await f.call("webProviderStart", ["provider": "gemini"])
                f.token = try XCTUnwrap(start["sessionToken"] as? String)
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while f.view.nativeLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(f.view.nativeLoading)
            let ready = try await f.evaluate("return window.fixtureReady===true;")
            XCTAssertEqual(ready as? Bool, true)
            f.view.fixtureURL = checkpoint
            f.view.fixtureLoading = true
            f.delegate.webView?(f.view, didStartProvisionalNavigation: f.navigation)
            return f
        }

        func block() async throws {
            let initial = try await call("webProviderPoll", ["sessionToken": token])
            XCTAssertEqual(initial["state"] as? String, "loading")
            settle(Self.checkpoint)
            await assertPollFailure(.humanVerificationRequired(.gemini))
        }

        func settle(_ url: URL) {
            view.fixtureURL = url
            delegate.webView?(view, didCommit: navigation)
            view.fixtureLoading = false
            delegate.webView?(view, didFinish: navigation)
        }

        func beginLocalNavigation(to url: URL) async throws {
            view.fixtureURL = url
            view.fixtureLoading = true
            navigation = try XCTUnwrap(view.loadHTMLString(Self.html, baseURL: Self.gemini))
            delegate.webView?(view, didStartProvisionalNavigation: navigation)
            let deadline = ContinuousClock.now + .seconds(10)
            while view.nativeLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(view.nativeLoading)
        }

        func call(_ operation: String, _ params: [String: String]) async throws -> [String: Any] {
            let data = try await transport.request(operation: operation, params: JSONSerialization.data(withJSONObject: params))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func finish(cancel: Bool = false) async throws -> [String: Any] {
            try await call(cancel ? "webProviderCancel" : "webProviderFinish", ["sessionToken": token])
        }

        func assertPollFailure(_ expected: EmbeddedWebModelTransport.Failure, file: StaticString = #filePath, line: UInt = #line) async {
            do { _ = try await call("webProviderPoll", ["sessionToken": token]); XCTFail("Expected original failure", file: file, line: line) }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, expected, file: file, line: line) }
        }

        func assertOriginalFailureAndNoInput(file: StaticString = #filePath, line: UInt = #line) async throws {
            await assertPollFailure(.humanVerificationRequired(.gemini), file: file, line: line)
            do { _ = try await call("webProviderSend", ["sessionToken": token, "prompt": "Never send"]); XCTFail("Saved gate", file: file, line: line) }
            catch { XCTAssertEqual(error as? EmbeddedWebModelTransport.Failure, .humanVerificationRequired(.gemini), file: file, line: line) }
            try await assertNoAdapterOrInput(file: file, line: line)
        }

        func assertNoAdapterOrInput(file: StaticString = #filePath, line: UInt = #line) async throws {
            let owner = try await evaluate("return globalThis.__computaModelOwner===undefined;", isolated: true)
            XCTAssertEqual(owner as? Bool, true, file: file, line: line)
            let counts = try await evaluate("return [window.fixtureInputs,window.fixtureClicks];")
            XCTAssertEqual(counts as? [Int], [0,0], file: file, line: line)
        }

        func evaluate(_ script: String, isolated: Bool = false) async throws -> Any {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                view.callAsyncJavaScript(script, arguments: [:], in: nil, in: isolated ? .world(name: "computa-chatgpt-model-v1") : .page) { result in
                    switch result {
                    case .success(let value):
                        do { continuation.resume(returning: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)) }
                        catch { continuation.resume(throwing: error) }
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
            return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        }

        func waitForPhysicalClose() async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while browser.webView(for: id) != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(browser.webView(for: id), "Original fixed timer must close even without Finish")
        }

        func assertHumanUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertTrue(browser.webView(for: humanID) === humanView, file: file, line: line)
            XCTAssertEqual(browser.selectedTabID, humanID, file: file, line: line)
            XCTAssertEqual(createdCount, 1, file: file, line: line)
        }

        func shutdown() {
            browser.shutdown()
            host.detach()
            window.orderOut(nil)
            window.close()
        }
    }
}

import ApplicationServices
import Foundation
import XCTest
@testable import HeyDash

/// Real Chrome/CDP/DOM on a disposable, explicitly owned headless profile.
/// The transport borrows only its preexisting fixture tab; the test owner alone
/// stops the child. Does NOT qualify ordinary-profile consent, UI focus or Qwen.
final class BorrowedChromeHeadlessLiveTests: XCTestCase {
    func testFiveSerialBorrowedDOMCyclesAndUnicodeWithoutTabLifecycleMutation() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless((env["HEYDASH_HEADLESS_BORROWED_GATE"] ?? env["TEST_RUNNER_HEYDASH_HEADLESS_BORROWED_GATE"]) == "1",
                          "Explicit isolated headless Chrome gate required.")
        try XCTSkipUnless(AXIsProcessTrusted(), "Existing Accessibility permission required; this test does not request it.")
        let executable = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: executable.path), "Installed Chrome required.")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Fixtures/BorrowedChromeFixture.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("heydash-headless-cdp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let child: OwnedChildProcess
        do {
            child = try OwnedChildProcess(executableURL: executable, arguments: [
                "--headless=new", "--no-first-run", "--no-default-browser-check",
                "--user-data-dir=\(profile.path)", "--remote-debugging-port=0",
                fixture.absoluteString,
            ])
        } catch {
            try? FileManager.default.removeItem(at: profile)
            throw error
        }
        var transport: BorrowedChromeDevToolsTransport?
        do {
            _ = try await endpoint(profile: profile, child: child)
            // The test owns this disposable profile and process. This exercises
            // the real file fence/factory/wire, not ordinary-profile attribution:
            // the production binder correctly rejects custom debugging argv.
            let consent = ChromeDebuggingConsent(approvedByUser: true)
            let endpointFile = try ChromeDebuggingEndpointFile.read(
                explicitlyApprovedUserDataDirectory: profile, consent: consent
            )
            let authority = ChromeDebuggingConnectionAuthority(endpoint: endpointFile.endpoint, consent: consent) {
                try endpointFile.validateIdentity()
                guard child.isRunning else { throw BrowserTabBrokerError.browserGenerationChanged }
            }
            let adapter = try await ChromeDebuggingConnection.connect(authority: authority)
            transport = adapter
            let broker = BrowserTabSessionBroker(transport: adapter, browserGeneration: adapter.generation, ownership: .borrowed)
            let candidates = try await adapter.listCandidates()
            let matches = candidates.filter { $0.url == fixture }
            XCTAssertEqual(matches.count, 1)
            let selected = try XCTUnwrap(matches.first)
            let target = try await adapter.attach(targetID: selected.targetID)
            var binding = try await broker.bindBorrowed(taskKey: "headless-fixture", processIdentifier: child.processIdentifier, target: target)
            let beforeIDs = Set(candidates.map(\.targetID))
            let clock = ContinuousClock()
            var cycleTimes = [Double]()
            for cycle in 1...5 {
                let started = clock.now
                var observation = try await broker.snapshot(taskKey: "headless-fixture", binding: binding, bundleIdentifier: "com.google.Chrome", query: nil)
                let button = try XCTUnwrap(observation.snapshot.elements.first { $0.label == "Increment fixture counter" && $0.supportsPress })
                try await broker.perform(taskKey: "headless-fixture", binding: observation.binding, snapshot: observation.snapshot, elementIndex: button.index, action: "AXPress")
                observation = try await broker.snapshot(taskKey: "headless-fixture", binding: observation.binding, bundleIdentifier: "com.google.Chrome", query: nil)
                XCTAssertTrue(observation.snapshot.formattedText.contains("Counter \(cycle)"))
                let input = try XCTUnwrap(observation.snapshot.elements.first { $0.supportsSetText && $0.label.contains("Fixture Unicode value") })
                let text = "HDé7-\(cycle) 東京 👋"
                try await broker.setText(taskKey: "headless-fixture", binding: observation.binding, snapshot: observation.snapshot, elementIndex: input.index, text: text)
                observation = try await broker.snapshot(taskKey: "headless-fixture", binding: observation.binding, bundleIdentifier: "com.google.Chrome", query: nil)
                XCTAssertEqual(observation.snapshot.elements.first { $0.supportsSetText }?.value, text)
                XCTAssertTrue(observation.snapshot.formattedText.contains("Value \(text)"))
                binding = observation.binding
                let elapsed = started.duration(to: clock.now).components
                cycleTimes.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            }
            try await broker.revoke(taskKey: "headless-fixture", binding: binding)
            await broker.invalidateAll()
            try await adapter.detach(target: target)
            let remaining = try await adapter.listCandidates()
            XCTAssertEqual(Set(remaining.map(\.targetID)), beforeIDs, "Borrowed cleanup cannot close or replace tabs.")
            XCTAssertTrue(child.isRunning, "Only the fixture owner can stop Chrome.")
            consent.revoke()
            do {
                _ = try await adapter.listCandidates()
                XCTFail("Revoked debugging consent must refuse further reads.")
            } catch let error as ChromeDebuggingEndpointError {
                XCTAssertEqual(error, .consentRequired)
            }
            await adapter.shutdown()
            let sorted = cycleTimes.sorted()
            print("HEYDASH_HEADLESS_BORROWED_OK cycles=5 counter=5 exact_unicode=true tabs_preserved=true guarded_factory=true consent_revocation=true ordinary_process_attribution=false model_used=false milliseconds=\(cycleTimes) median_ms=\(sorted[2])")
        } catch {
            await transport?.shutdown()
            let stopped = await child.stop()
            if stopped.succeeded { try? FileManager.default.removeItem(at: profile) }
            XCTAssertTrue(stopped.succeeded, "Failed fixture must still clean up its exact owned child; preserve profile if not proven stopped.")
            throw error
        }
        let stopped = await child.stop()
        XCTAssertTrue(stopped.succeeded)
        if stopped.succeeded { try FileManager.default.removeItem(at: profile) }
    }

    private func endpoint(profile: URL, child: OwnedChildProcess) async throws -> URL {
        let file = profile.appendingPathComponent("DevToolsActivePort")
        for _ in 0..<200 {
            try Task.checkCancellation()
            guard child.isRunning else { throw BrowserTabBrokerError.browserUnavailable("isolated fixture exited before readiness") }
            if let bytes = try? Data(contentsOf: file), bytes.count < 1_024,
               let text = String(data: bytes, encoding: .utf8) {
                let lines = text.split(separator: "\n")
                if lines.count == 2, let port = UInt16(lines[0]), port > 0,
                   let url = URL(string: "ws://127.0.0.1:\(port)\(lines[1])") {
                    try URLSessionBrowserCDPWire.validate(endpoint: url)
                    return url
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BrowserTabBrokerError.browserUnavailable("isolated fixture endpoint readiness timed out")
    }
}

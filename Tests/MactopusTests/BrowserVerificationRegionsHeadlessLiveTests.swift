import ApplicationServices
import Foundation
import XCTest
@testable import Mactopus

/// Real Chrome/CDP and changing DOM identities on an isolated owned profile.
/// No signed-in profile, foreground, model, extension or app approval claim.
final class BrowserVerificationRegionsHeadlessLiveTests: XCTestCase {
    func testTextChildAndNamedContainerReplacementVerifyWithoutReplayingInput() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless((env["HEYDASH_HEADLESS_BORROWED_GATE"] ?? env["TEST_RUNNER_HEYDASH_HEADLESS_BORROWED_GATE"]) == "1",
                          "Explicit isolated headless Chrome gate required.")
        try XCTSkipUnless(AXIsProcessTrusted(), "Existing Accessibility permission required; this test does not request it.")
        let executable = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: executable.path), "Installed Chrome required.")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BrowserVerificationRegions.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("mactopus-region-verification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let child: OwnedChildProcess
        do {
            child = try OwnedChildProcess(executableURL: executable, arguments: [
                "--headless=new", "--no-first-run", "--no-default-browser-check",
                "--user-data-dir=\(profile.path)", "--remote-debugging-port=0", fixture.absoluteString,
            ])
        } catch {
            try? FileManager.default.removeItem(at: profile)
            throw error
        }
        var transport: BorrowedChromeDevToolsTransport?
        do {
            try await awaitEndpoint(profile: profile, child: child)
            let consent = ChromeDebuggingConsent(approvedByUser: true)
            let endpoint = try ChromeDebuggingEndpointFile.read(explicitlyApprovedUserDataDirectory: profile, consent: consent)
            let authority = ChromeDebuggingConnectionAuthority(endpoint: endpoint.endpoint, consent: consent) {
                try endpoint.validateIdentity()
                guard child.isRunning else { throw BrowserTabBrokerError.browserGenerationChanged }
            }
            let adapter = try await ChromeDebuggingConnection.connect(authority: authority)
            transport = adapter
            let broker = BrowserTabSessionBroker(transport: adapter, browserGeneration: adapter.generation, ownership: .borrowed)
            let candidates = try await adapter.listCandidates()
            let selected = try XCTUnwrap(candidates.first { $0.url == fixture })
            let target = try await adapter.attach(targetID: selected.targetID)
            var binding = try await broker.bindBorrowed(taskKey: "region-fixture", processIdentifier: child.processIdentifier, target: target)
            let originalTabs = Set(candidates.map(\.targetID))
            var observed = try await broker.snapshot(taskKey: "region-fixture", binding: binding, bundleIdentifier: "com.google.Chrome", query: nil)
            var times: [Double] = []
            for (offset, buttonName) in ["Replace result text child", "Replace named result container"].enumerated() {
                let before = observed.snapshot
                let button = try XCTUnwrap(before.elements.first { $0.label == buttonName && $0.supportsPress })
                let region = try XCTUnwrap(before.elements.first { $0.semanticRole?.lowercased() == "status" && $0.label == "Fixture result" })
                let oldTextID = try XCTUnwrap(before.evidenceDocument?.nodes.first {
                    $0.role.lowercased() == "statictext" && $0.name == "Count: \(offset)"
                }?.backendNodeID)
                let expected = "Count: \(offset + 1)"
                let plan = try XCTUnwrap(BrowserActionVerification.compile(
                    request: .init(kind: .regionText, elementIndex: region.index, expected: expected),
                    action: .press, elementIndex: button.index, snapshot: before, binding: observed.binding))
                let clock = ContinuousClock(), started = clock.now
                try await broker.perform(taskKey: "region-fixture", binding: observed.binding, snapshot: before,
                    elementIndex: button.index, action: "AXPress", verificationPlan: plan)
                // Verification may re-read a settling page, but the only press
                // is above this loop and can never be replayed by a mismatch.
                var proof: BrowserActionVerification.Proof?
                for attempt in 0..<3 {
                    observed = try await broker.snapshot(taskKey: "region-fixture", binding: observed.binding,
                        bundleIdentifier: "com.google.Chrome", query: nil)
                    proof = try? plan.evaluate(binding: observed.binding, snapshot: observed.snapshot)
                    if proof != nil { break }
                    if attempt < 2 { try await Task.sleep(for: .milliseconds(100)) }
                }
                XCTAssertEqual(try XCTUnwrap(proof).expectedValue, expected)
                let freshRegion = try XCTUnwrap(observed.snapshot.evidenceDocument?.nodes.first {
                    $0.role.lowercased() == "status" && $0.name == "Fixture result"
                })
                let freshTextID = try XCTUnwrap(observed.snapshot.evidenceDocument?.nodes.first {
                    $0.role.lowercased() == "statictext" && $0.name == expected
                }?.backendNodeID)
                XCTAssertNotEqual(freshTextID, oldTextID, "This gate must actually replace the text DOM node.")
                if offset == 0 { XCTAssertEqual(freshRegion.backendNodeID, region.backendNodeID) }
                else { XCTAssertNotEqual(freshRegion.backendNodeID, region.backendNodeID, "The second gate must replace the container itself.") }
                let dispatchCount = observed.snapshot.evidenceDocument?.nodes.first {
                    $0.role.lowercased() == "textbox" && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == "Input dispatch count"
                }?.value
                XCTAssertEqual(dispatchCount, String(offset + 1), "Each mode must dispatch exactly one click, not recover by replaying.")
                binding = observed.binding
                let elapsed = started.duration(to: clock.now).components
                times.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            }
            try await broker.revoke(taskKey: "region-fixture", binding: binding)
            await broker.invalidateAll()
            try await adapter.detach(target: target)
            let remainingTabs = try await adapter.listCandidates()
            XCTAssertEqual(Set(remainingTabs.map(\.targetID)), originalTabs)
            XCTAssertTrue(child.isRunning)
            consent.revoke()
            await adapter.shutdown()
            print("MACTOPUS_REGION_VERIFICATION_OK cases=2 dispatched_clicks=2 child_identity_changed=true container_identity_changed=true signed_in_chrome=false model_used=false milliseconds=\(times)")
        } catch {
            await transport?.shutdown()
            let stopped = await child.stop()
            if stopped.succeeded { try? FileManager.default.removeItem(at: profile) }
            XCTAssertTrue(stopped.succeeded, "Preserve disposable profile unless exact owned child termination is proven.")
            throw error
        }
        let stopped = await child.stop()
        XCTAssertTrue(stopped.succeeded)
        if stopped.succeeded { try FileManager.default.removeItem(at: profile) }
    }

    private func awaitEndpoint(profile: URL, child: OwnedChildProcess) async throws {
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
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BrowserTabBrokerError.browserUnavailable("isolated fixture endpoint readiness timed out")
    }
}

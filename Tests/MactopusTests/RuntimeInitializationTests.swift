import Darwin
import Foundation
import XCTest
@testable import Mactopus

/// Exercises the production startup state machine with an owned JSON-RPC
/// fixture. Effective backend remains external: no model or port is touched.
@MainActor
final class RuntimeInitializationTests: XCTestCase {
    func testRejectedInitializationReapsOwnedTransportBeforeReturning() async throws {
        let (runtime, root) = try makeRuntime(mode: "reject")
        do { _ = try await runtime.loadTasks(); XCTFail("Fixture must reject initialization") }
        catch { XCTAssertTrue(error.localizedDescription.contains("fixture initialize rejection")) }
        try assertFixtureGone(root)
        let report = await runtime.shutdown()
        XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
    }

    func testStructuredErrorSurvivesActualTransportAndCleanup() async throws {
        let (runtime, root) = try makeRuntime(mode: "reject-structured")
        do { _ = try await runtime.loadTasks(); XCTFail("Fixture must reject initialization") }
        catch {
            let rpc = try XCTUnwrap(error as? AgentRPCError)
            XCTAssertEqual(rpc.code, -32603)
            XCTAssertEqual(rpc.localizedDescription, "fixture reconciliation required")
            let payload = try JSONSerialization.jsonObject(with: XCTUnwrap(rpc.data)) as? NSDictionary
            XCTAssertEqual(payload, ["reason": "poisoned", "reconcileRequired": true, "marker": "preserve-🧭"] as NSDictionary)
        }
        try assertFixtureGone(root)
        let report = await runtime.shutdown()
        XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
    }

    func testCancellationOfPendingInitializationReapsOwnedTransport() async throws {
        let (runtime, root) = try makeRuntime(mode: "wait")
        let loading = Task { try await runtime.loadTasks() }
        do {
            try await waitForInitialize(root)
            loading.cancel()
            do { _ = try await loading.value; XCTFail("Cancellation must end initialization") }
            catch { XCTAssertTrue(error is CancellationError) }
            try assertFixtureGone(root)
            let report = await runtime.shutdown()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
        } catch {
            loading.cancel()
            _ = await runtime.shutdown()
            throw error
        }
    }

    private func makeRuntime(mode: String) throws -> (CodexAppServerRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MactopusInitialization-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        try Data(mode.utf8).write(to: root.appendingPathComponent("mode"))
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/InitializationAppServer.ts")
        let fixture = root.appendingPathComponent("fixture.ts")
        try FileManager.default.copyItem(at: source, to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.executable = .fixture(path: fixture.path)
        configuration.codexHomePath = root.path
        return (CodexAppServerRuntime(configuration: configuration), root)
    }

    private func waitForInitialize(_ root: URL) async throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("initialize-received").path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "Initialization fixture did not start", code: 1)
    }

    private func assertFixtureGone(_ root: URL) throws {
        let text = try String(contentsOf: root.appendingPathComponent("fixture-pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(text))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}

import Foundation
import XCTest
@testable import Computa

@MainActor
final class HeadlessMLXServerTests: XCTestCase {
    func testDefaultPreservesProviderIdentityAndExplicitExternalFallback() throws {
        let native = CodexAppServerRuntime.Configuration.localQwen
        let external = CodexAppServerRuntime.Configuration.externalLocalQwen
        XCTAssertEqual(native.effectiveBackend, .headlessMLX)
        XCTAssertEqual(external.effectiveBackend, .external)
        XCTAssertEqual(native.modelProvider, "lmstudio")
        XCTAssertEqual(external.modelProvider, native.modelProvider)
        XCTAssertEqual(native.codexHomePath, external.codexHomePath)
        XCTAssertEqual(native.model, "lmstudio-community/Qwen3.5-4B-MLX-4bit")
        XCTAssertTrue(native.requiresLocalModelPreflight)
        XCTAssertTrue(external.requiresLocalModelPreflight)
        for model in ["lmstudio-community/Qwen3.5-4B-MLX-4bit", "lmstudio-community/Qwen3.5-9B-MLX-4bit"] {
            XCTAssertNoThrow(try native.validateSelectedModel(model))
        }
        for model in ["mlx-community/Qwen3.8-27B-4bit", "lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit", "unlisted"] {
            XCTAssertThrowsError(try native.validateSelectedModel(model))
            XCTAssertNoThrow(try external.validateSelectedModel(model))
        }
        var fixture = native
        fixture.executable = .fixture(path: "/not-executed")
        XCTAssertEqual(fixture.effectiveBackend, .external)
        XCTAssertFalse(fixture.requiresLocalModelPreflight)
    }

    func testHeadlessLaunchEndpointCannotInheritAnUnrelatedProviderDestination() throws {
        let inherited = ["CODEX_OSS_BASE_URL": "https://unrelated.example/v1", "CODEX_OSS_PORT": "1234", "OTHER": "preserved"]
        let headless = LocalInferenceBackend.headlessMLX.launchEnvironment(inherited)
        XCTAssertEqual(headless, ["CODEX_OSS_BASE_URL": "http://127.0.0.1:1237/v1", "OTHER": "preserved"])
        XCTAssertEqual(LocalInferenceBackend.external.launchEnvironment(inherited), inherited)
        XCTAssertEqual(try LocalModelServerPreflight.endpoint(launchEnvironment: headless).absoluteString,
                       "http://127.0.0.1:1237/v1/models")
    }

    func testLaunchUsesOnlyOwnedResourcePathsAndNoPrivateEnvironment() {
        let configuration = configuration()
        XCTAssertEqual(configuration.arguments, ["-B", "-u", "/fixture/server.py", "--port", "1237", "--model-root", "/fixture/models",
                                                 "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)])
        let environment = configuration.environment(instance: "owned")
        XCTAssertEqual(environment["HEYDASH_MLX_INSTANCE"], "owned")
        XCTAssertEqual(environment["HF_HUB_OFFLINE"], "1")
        XCTAssertEqual(environment["PYTHONDONTWRITEBYTECODE"], "1")
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["PYTHONPATH"])
        XCTAssertNil(environment["HTTP_PROXY"])
    }

    func testBundledPythonResourcesContainOnlySourcesAndNoGeneratedCaches() throws {
        let configuration = try HeadlessMLXConfiguration.local()
        let resources = try FileManager.default.contentsOfDirectory(
            at: configuration.script.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(resources.map(\.lastPathComponent)), ["server.py", "response_boundary.py", "sse_contract.py"])
    }

    func testOwnedMLXInstallationIsPreferredWithoutRequiringLegacyEnvironment() {
        let owned = "/fixture/support/LocalCodex/MLX/venv/bin/python"
        let legacy = "/fixture/support/LocalCodex/VisualGrounding/venv/bin/python"
        for executables in [Set([owned]), Set([owned, legacy]), Set<String>()] {
            let paths = HeadlessMLXConfiguration.localPaths(
                support: URL(fileURLWithPath: "/fixture/support"), home: URL(fileURLWithPath: "/fixture/home"),
                script: URL(fileURLWithPath: "/fixture/server.py"), isExecutable: executables.contains)
            XCTAssertEqual(paths.python.path, owned)
            XCTAssertEqual(paths.modelRoot.path, "/fixture/support/LocalCodex/MLX/models")
            XCTAssertEqual(paths.fallbackModelRoot?.path, "/fixture/home/.lmstudio/models")
            XCTAssertTrue(paths.arguments.contains("--fallback-model-root"))
        }
    }

    func testExistingGroundingPythonIsFallbackButModelRootsRemainIndependent() {
        let legacy = "/fixture/support/LocalCodex/VisualGrounding/venv/bin/python"
        let paths = HeadlessMLXConfiguration.localPaths(
            support: URL(fileURLWithPath: "/fixture/support"), home: URL(fileURLWithPath: "/fixture/home"),
            script: URL(fileURLWithPath: "/fixture/server.py"), isExecutable: { $0 == legacy })
        XCTAssertEqual(paths.python.path, legacy)
        XCTAssertEqual(paths.modelRoot.path, "/fixture/support/LocalCodex/MLX/models")
        XCTAssertEqual(paths.fallbackModelRoot?.path, "/fixture/home/.lmstudio/models")
    }

    func testHealthRequiresMatchingUUIDAndHealthyStatusWithoutTrustingOtherFields() throws {
        let nonce = UUID().uuidString
        XCTAssertTrue(HeadlessMLXServer.ownsHealthyResponse(try health(nonce.lowercased()), instance: nonce))
        for body in ["{}", "{\"status\":\"healthy\",\"heydash_instance\":\"invalid\"}",
                     "{\"status\":\"starting\",\"heydash_instance\":\"\(nonce)\"}"] {
            XCTAssertFalse(HeadlessMLXServer.ownsHealthyResponse(.init(status: 200, body: Data(body.utf8)), instance: nonce))
        }
        XCTAssertFalse(HeadlessMLXServer.ownsHealthyResponse(try health(UUID().uuidString), instance: nonce))
        XCTAssertFalse(HeadlessMLXServer.ownsHealthyResponse(.init(status: 302, body: try health(nonce).body), instance: nonce))
        XCTAssertFalse(HeadlessMLXServer.ownsHealthyResponse(.init(status: 200, body: Data(repeating: 32, count: 4097)), instance: nonce))
    }

    func testRepeatedStartOwnsExactlyOneChildAndShutdownIsIdempotent() async throws {
        let fixture = Fixture(mode: .ready)
        let server = HeadlessMLXServer(configuration: configuration(), operations: fixture.operations)
        try await server.start()
        try await server.start()
        XCTAssertEqual(fixture.launchCount, 1)
        XCTAssertEqual(fixture.child.stopCount, 0)
        let first = await server.shutdown()
        let second = await server.shutdown()
        XCTAssertEqual(first, [])
        XCTAssertEqual(second, [])
        XCTAssertEqual(fixture.child.stopCount, 1)
        do { try await server.start(); XCTFail("A stopped owner must not relaunch") }
        catch { XCTAssertEqual(error as? HeadlessMLXServer.Failure, .stopped) }
    }

    func testExistingListenerIsNeverAdoptedOrStopped() async {
        let fixture = Fixture(mode: .occupied)
        let server = HeadlessMLXServer(configuration: configuration(), operations: fixture.operations)
        do { try await server.start(); XCTFail("Must reject an occupied endpoint") }
        catch { XCTAssertEqual(error as? HeadlessMLXServer.Failure, .portOccupied) }
        XCTAssertEqual(fixture.launchCount, 0)
        XCTAssertEqual(fixture.child.stopCount, 0)
    }

    func testWrongNonceAfterSpawnStopsOnlyTheOwnedChild() async {
        let fixture = Fixture(mode: .wrongNonce)
        let server = HeadlessMLXServer(configuration: configuration(), operations: fixture.operations)
        do { try await server.start(); XCTFail("Must reject wrong ownership") }
        catch { XCTAssertEqual(error as? HeadlessMLXServer.Failure, .portOccupied) }
        XCTAssertEqual(fixture.launchCount, 1)
        XCTAssertEqual(fixture.child.stopCount, 1)
        let issues = await server.shutdown()
        XCTAssertEqual(issues, [])
        XCTAssertEqual(fixture.child.stopCount, 1)
    }

    func testStartupTimeoutStopsOwnedChildWithoutAnInferenceRequest() async {
        let fixture = Fixture(mode: .neverReady)
        var config = configuration()
        config.startupTimeout = .milliseconds(1)
        let server = HeadlessMLXServer(configuration: config, operations: fixture.operations)
        do { try await server.start(); XCTFail("Must time out") }
        catch { XCTAssertEqual(error as? HeadlessMLXServer.Failure, .timedOut) }
        XCTAssertEqual(fixture.launchCount, 1)
        XCTAssertEqual(fixture.child.stopCount, 1)
    }

    func testCancellationDuringHealthWaitReapsOwnedChild() async {
        let fixture = Fixture(mode: .neverReady)
        let server = HeadlessMLXServer(configuration: configuration(), operations: fixture.operations)
        let starting = Task { try await server.start() }
        for _ in 0..<100 where fixture.launchCount == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        starting.cancel()
        do { try await starting.value; XCTFail("Must honor cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.child.stopCount, 1)
        XCTAssertEqual(fixture.launchCount, 1)
    }

    func testConcurrentStartupSharesOneOwnedChild() async throws {
        let fixture = Fixture(mode: .ready)
        let server = HeadlessMLXServer(configuration: configuration(), operations: fixture.operations)
        async let first: Void = server.start()
        async let second: Void = server.start()
        try await first
        try await second
        XCTAssertEqual(fixture.launchCount, 1)
        let issues = await server.shutdown()
        XCTAssertEqual(issues, [])
        XCTAssertEqual(fixture.child.stopCount, 1)
    }

    func testExitedChildCannotReuseSuccessfulStartupOrAdoptReplacement() async throws {
        let fixture = Fixture(mode: .ready)
        let server = HeadlessMLXServer(configuration: configuration(), operations: fixture.operations)
        try await server.start()
        fixture.child.simulateExit()
        do { try await server.start(); XCTFail("A prior readiness response is not current liveness") }
        catch { XCTAssertEqual(error as? HeadlessMLXServer.Failure, .exited) }
        XCTAssertEqual(fixture.launchCount, 1)
        XCTAssertEqual(fixture.child.stopCount, 1)
    }

    func testShutdownDuringStartupDoesNotLeakOrRelaunch() async {
        let fixture = Fixture(mode: .neverReady)
        let server = HeadlessMLXServer(configuration: configuration(), operations: fixture.operations)
        let starting = Task { try await server.start() }
        for _ in 0..<100 where fixture.launchCount == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        let issues = await server.shutdown()
        XCTAssertEqual(issues, [])
        do { try await starting.value; XCTFail("A shutdown owner cannot become ready") }
        catch { XCTAssertTrue(error is CancellationError || error as? HeadlessMLXServer.Failure == .stopped) }
        XCTAssertEqual(fixture.launchCount, 1)
        XCTAssertEqual(fixture.child.stopCount, 1)
    }

    func testCleanupFailureIsNotReportedAsSuccessfulShutdown() async {
        let fixture = Fixture(mode: .neverReady, cleanupIssues: ["fixture child not reaped"])
        var config = configuration()
        config.startupTimeout = .milliseconds(1)
        let server = HeadlessMLXServer(configuration: config, operations: fixture.operations)
        do { try await server.start(); XCTFail("Cleanup failure must surface") }
        catch { XCTAssertEqual(error as? HeadlessMLXServer.Failure, .cleanup(["fixture child not reaped"])) }
        let issues = await server.shutdown()
        XCTAssertEqual(issues, ["fixture child not reaped"])
    }

    func testModelSelectionReusesFirstProcessButRotatesEachDifferentModelAfterReaping() async throws {
        let fixture = RotationFixture()
        let server = HeadlessMLXServer(configuration: configuration(), operations: fixture.operations)
        let small = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
        let large = "lmstudio-community/Qwen3.5-9B-MLX-4bit"
        try await server.start()
        try await server.prepare(modelID: small, activity: .init())
        try await server.prepare(modelID: small, activity: .init())
        XCTAssertEqual(fixture.children.count, 1)
        try await server.prepare(modelID: large, activity: .init())
        XCTAssertEqual(fixture.children.map(\.stopCount), [1, 0])
        try await server.prepare(modelID: small, activity: .init())
        XCTAssertEqual(fixture.children.map(\.stopCount), [1, 1, 0])
        XCTAssertEqual(Set(fixture.instances).count, 3)
        XCTAssertFalse(fixture.overlappedProcesses)
        let issues = await server.shutdown()
        XCTAssertEqual(issues, [])
        XCTAssertEqual(fixture.children.map(\.stopCount), [1, 1, 1])
    }

    func testEveryNativeBusySourcePreventsModelSwitchWithoutStoppingOwner() async throws {
        let fixture = RotationFixture()
        let server = HeadlessMLXServer(configuration: configuration(), operations: fixture.operations)
        try await server.prepare(modelID: "lmstudio-community/Qwen3.5-4B-MLX-4bit", activity: .init())
        for activity in [
            HeadlessMLXWorkState(activeOrStartingTurn: true),
            .init(competingSubmission: true), .init(compaction: true),
            .init(toolInFlight: true), .init(selectionInProgress: true),
        ] {
            do {
                try await server.prepare(modelID: "lmstudio-community/Qwen3.5-9B-MLX-4bit", activity: activity)
                XCTFail("Any producer still owning inference must block replacement")
            } catch { XCTAssertEqual(error as? HeadlessMLXServer.Failure, .busy) }
        }
        XCTAssertEqual(fixture.children.map(\.stopCount), [0])
        _ = await server.shutdown()
    }

    func testHTTPWorkerBusyBlocksRotationAfterNativeTurnHasEnded() async throws {
        let fixture = RotationFixture()
        let server = HeadlessMLXServer(configuration: configuration(), operations: fixture.operations)
        try await server.prepare(modelID: "lmstudio-community/Qwen3.5-4B-MLX-4bit", activity: .init())
        fixture.setBusy(true)
        do {
            try await server.prepare(modelID: "lmstudio-community/Qwen3.5-9B-MLX-4bit", activity: .init())
            XCTFail("HTTP worker cleanup must finish before process replacement")
        } catch { XCTAssertEqual(error as? HeadlessMLXServer.Failure, .busy) }
        XCTAssertEqual(fixture.children.map(\.stopCount), [0])
        _ = await server.shutdown()
    }

    func testUnverifiedOldCleanupNeverStartsReplacementModel() async throws {
        let fixture = RotationFixture(cleanupIssues: ["old process group remains"])
        let server = HeadlessMLXServer(configuration: configuration(), operations: fixture.operations)
        try await server.prepare(modelID: "lmstudio-community/Qwen3.5-4B-MLX-4bit", activity: .init())
        do {
            try await server.prepare(modelID: "lmstudio-community/Qwen3.5-9B-MLX-4bit", activity: .init())
            XCTFail("Failed cleanup must not permit second weights process")
        } catch { XCTAssertEqual(error as? HeadlessMLXServer.Failure, .cleanup(["old process group remains"])) }
        XCTAssertEqual(fixture.children.count, 1)
        _ = await server.shutdown()
    }

    func testCancellationDuringOldProcessCleanupDoesNotLaunchReplacement() async throws {
        let fixture = RotationFixture(stopDelay: .milliseconds(30))
        let server = HeadlessMLXServer(configuration: configuration(), operations: fixture.operations)
        try await server.prepare(modelID: "lmstudio-community/Qwen3.5-4B-MLX-4bit", activity: .init())
        let switching = Task {
            try await server.prepare(modelID: "lmstudio-community/Qwen3.5-9B-MLX-4bit", activity: .init())
        }
        for _ in 0..<100 where fixture.children.first?.stopCount == 0 { try await Task.sleep(for: .milliseconds(1)) }
        switching.cancel()
        do { try await switching.value; XCTFail("Cancelled model selection must not load replacement") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.children.count, 1)
        let issues = await server.shutdown()
        XCTAssertEqual(issues, [])
    }

    func testTurnIdentityBusyIncludesUnacknowledgedStartAndClearsOnlyExactTerminal() {
        var identity = AppServerTurnIdentityTracker()
        XCTAssertFalse(identity.hasActiveOrStartingTurns)
        let token = identity.beginStart(taskID: "a")
        XCTAssertTrue(identity.hasActiveOrStartingTurns)
        identity.acknowledgeStart(taskID: "a", turnID: "turn-a", token: token)
        XCTAssertFalse(identity.complete(taskID: "a", turnID: "stale"))
        XCTAssertTrue(identity.hasActiveOrStartingTurns)
        XCTAssertTrue(identity.complete(taskID: "a", turnID: "turn-a"))
        XCTAssertFalse(identity.hasActiveOrStartingTurns)
    }

    private func configuration() -> HeadlessMLXConfiguration {
        .init(python: URL(fileURLWithPath: "/fixture/python"), script: URL(fileURLWithPath: "/fixture/server.py"),
              modelRoot: URL(fileURLWithPath: "/fixture/models"))
    }

    private func health(_ instance: String) throws -> HeadlessMLXServer.Health {
        .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["status": "healthy", "heydash_instance": instance]))
    }
}

private final class Fixture: @unchecked Sendable {
    enum Mode { case ready, occupied, wrongNonce, neverReady }
    private let lock = NSLock()
    private let mode: Mode
    private var nonce: String?
    private var launches = 0
    let child: FakeMLXChild
    init(mode: Mode, cleanupIssues: [String] = []) {
        self.mode = mode
        child = FakeMLXChild(cleanupIssues: cleanupIssues)
    }
    var launchCount: Int { lock.withLock { launches } }
    var operations: HeadlessMLXServer.Operations {
        .init(launch: { [self] _, instance in
            lock.withLock { nonce = instance; launches += 1 }
            return child
        }, health: { [self] url in
            guard url.path == "/health" else { throw HeadlessMLXServer.Failure.unavailable("Unexpected request") }
            return try lock.withLock {
                if mode == .occupied { return .init(status: 200, body: Data("{}".utf8)) }
                guard let nonce, mode != .neverReady else { return nil }
                let identity = mode == .wrongNonce ? UUID().uuidString : nonce
                return .init(status: 200, body: try JSONSerialization.data(withJSONObject:
                    ["status": "healthy", "heydash_instance": identity]))
            }
        })
    }
}

private final class FakeMLXChild: HeadlessMLXProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var stops = 0
    private var exited = false
    private let cleanupIssues: [String]
    private let stopDelay: Duration
    init(cleanupIssues: [String] = [], stopDelay: Duration = .zero) {
        self.cleanupIssues = cleanupIssues
        self.stopDelay = stopDelay
    }
    var stopCount: Int { lock.withLock { stops } }
    var isRunning: Bool { lock.withLock { stops == 0 && !exited } }
    func simulateExit() { lock.withLock { exited = true } }
    func stop() async -> OwnedChildProcess.StopResult {
        lock.withLock { stops += 1 }
        if stopDelay > .zero { try? await Task.sleep(for: stopDelay) }
        return .init(rootReaped: cleanupIssues.isEmpty, groupGone: cleanupIssues.isEmpty, issues: cleanupIssues)
    }
}

private final class RotationFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let cleanupIssues: [String]
    private let stopDelay: Duration
    private var spawned: [FakeMLXChild] = []
    private var nonces: [String] = []
    private var busy = false
    private var overlap = false
    init(cleanupIssues: [String] = [], stopDelay: Duration = .zero) {
        self.cleanupIssues = cleanupIssues
        self.stopDelay = stopDelay
    }
    var children: [FakeMLXChild] { lock.withLock { spawned } }
    var instances: [String] { lock.withLock { nonces } }
    var overlappedProcesses: Bool { lock.withLock { overlap } }
    func setBusy(_ value: Bool) { lock.withLock { busy = value } }
    var operations: HeadlessMLXServer.Operations {
        .init(launch: { [self] _, nonce in
            lock.withLock {
                overlap = overlap || spawned.contains { $0.isRunning }
                let child = FakeMLXChild(cleanupIssues: cleanupIssues, stopDelay: stopDelay)
                spawned.append(child)
                nonces.append(nonce)
                return child
            }
        }, health: { [self] _ in
            try lock.withLock {
                guard let child = spawned.last, child.isRunning, let nonce = nonces.last else { return nil }
                return .init(status: 200, body: try JSONSerialization.data(withJSONObject:
                    ["status": "healthy", "heydash_instance": nonce, "busy": busy]))
            }
        })
    }
}

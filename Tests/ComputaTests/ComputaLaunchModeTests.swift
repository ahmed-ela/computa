import XCTest
@testable import Computa

@MainActor
final class ComputaLaunchModeTests: XCTestCase {
    func testEachXCTestMarkerSelectsInertHostEvenBeforeFrameworkLoads() {
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            for value in ["test-value", ""] {
                XCTAssertEqual(ComputaLaunchMode.detect(environment: [key: value],
                                                       xctestClassLoaded: false), .testHost, key)
            }
        }
    }

    func testLoadedXCTestFrameworkIsAnIndependentFallback() {
        XCTAssertEqual(ComputaLaunchMode.detect(environment: [:], xctestClassLoaded: true), .testHost)
    }

    func testOrdinaryAndLiveFixtureFlagsDoNotChangeApplicationMode() {
        XCTAssertEqual(ComputaLaunchMode.detect(environment: [:], xctestClassLoaded: false), .application)
        XCTAssertEqual(ComputaLaunchMode.detect(environment: ["TEST_RUNNER_LOCALCODEX_LIVE_MODEL_ID": "fixture"],
                                               xctestClassLoaded: false), .application)
    }

    func testActualXCTestProcessIsRecognized() {
        XCTAssertEqual(ComputaLaunchMode.current, .testHost)
    }

    func testHostNeverConstructsProductionRuntimeOrReadsProductionPreferences() async {
        let state = ComputaLaunchMode.testHost.makeState(
            runtimeFactory: {
                XCTFail("Test-host composition must not construct a production runtime")
                return LaunchModeRuntimeSpy()
            },
            preferencesFactory: {
                XCTFail("Test-host composition must not access production preferences")
                return self.isolatedTestPreferences()
            }
        )
        await state.startRuntime()
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertEqual(state.connectionState, .disconnected)
        XCTAssertEqual(state.accessMode, .askEveryTime)
        XCTAssertEqual(state.defaultModel, LocalModelCatalog.defaultModelID)
        XCTAssertEqual(state.automationPermissions.accessibility, .notGranted)
        XCTAssertEqual(state.automationPermissions.screenRecording, .notGranted)
        let shutdown = await state.shutdownRuntime()
        XCTAssertTrue(shutdown.succeeded)
    }

    func testApplicationStillUsesInjectedRuntimeAndPreferences() async {
        let runtime = LaunchModeRuntimeSpy()
        let preferences = isolatedTestPreferences()
        preferences.set(AccessMode.fullAccess.rawValue, forKey: "HeyDash.accessMode")
        var runtimeConstructions = 0
        var preferenceReads = 0
        let state = ComputaLaunchMode.application.makeState(
            runtimeFactory: { runtimeConstructions += 1; return runtime },
            preferencesFactory: { preferenceReads += 1; return preferences }
        )
        XCTAssertEqual(runtimeConstructions, 1)
        XCTAssertEqual(preferenceReads, 1)
        XCTAssertEqual(state.accessMode, .fullAccess)
        await state.startRuntime()
        XCTAssertEqual(state.connectionState, .connected(provider: runtime.providerName))
        let loadCount = await runtime.loadCount
        XCTAssertEqual(loadCount, 1)
        _ = await state.shutdownRuntime()
    }
}

private actor LaunchModeRuntimeSpy: AgentRuntimeClient {
    nonisolated let providerName = "Launch-mode fixture"
    private(set) var loadCount = 0

    func loadTasks() async throws -> [AgentTask] { loadCount += 1; return [] }
    nonisolated func events() -> AsyncStream<AgentRuntimeEvent> { AsyncStream { $0.finish() } }
    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {
        XCTFail("No model submission is expected during composition")
    }
    func interrupt(taskID: AgentTask.ID) async throws {}
    func resolveApproval(requestID: String, approved: Bool) async throws {}
}

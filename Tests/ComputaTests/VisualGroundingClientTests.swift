import Foundation
import XCTest
@testable import Computa

@MainActor
final class VisualGroundingClientTests: XCTestCase {
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testResidencyGateAllowsOnlyOneMemoryFamilyAtATime() {
        var gate = VisualGroundingResidencyGate()

        XCTAssertTrue(gate.reserve(taskID: "visual-a", supportsSidecar: true))
        XCTAssertTrue(gate.reserve(taskID: "visual-b", supportsSidecar: true))
        XCTAssertFalse(gate.reserve(taskID: "large-a", supportsSidecar: false))
        XCTAssertTrue(gate.allowsSidecar)

        gate.release(taskID: "visual-a")
        gate.release(taskID: "visual-b")
        XCTAssertTrue(gate.reserve(taskID: "large-a", supportsSidecar: false))
        XCTAssertFalse(gate.reserve(taskID: "visual-c", supportsSidecar: true))
        XCTAssertFalse(gate.allowsSidecar)

        gate.release(taskID: "large-a")
        XCTAssertTrue(gate.reserve(taskID: "visual-c", supportsSidecar: true))
        XCTAssertTrue(gate.allowsSidecar)
    }

    func testResidencyGateFailsClosedForRestoredMixedTurns() {
        var gate = VisualGroundingResidencyGate()
        gate.restoreActive(taskID: "visual", supportsSidecar: true)
        gate.restoreActive(taskID: "large", supportsSidecar: false)

        XCTAssertFalse(gate.allowsSidecar)
        XCTAssertFalse(gate.reserve(taskID: "another-visual", supportsSidecar: true))
        XCTAssertFalse(gate.reserve(taskID: "another-large", supportsSidecar: false))
    }

    func testPrepareStartsWorkerBeforeFirstGroundingRequest() async throws {
        let harness = try makeHarness(script: Self.respondingWorker)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let client = PythonVisualGroundingClient(configuration: harness.configuration)

        try await client.prepare()
        let decision = try await client.ground(VisualGroundingRequest(
            id: UUID(),
            png: Data([1]),
            width: 1,
            height: 1,
            target: "Test button"
        ))

        XCTAssertEqual(decision.point, VisualGroundingPoint(x: 0.25, y: 0.25))
        let shutdownIssues = await client.shutdown()
        XCTAssertTrue(shutdownIssues.isEmpty)
    }

    func testCancelledPrepareBeforeEntryDoesNotStartWorker() async throws {
        let harness = try makeHarness(script: Self.respondingWorker, recordsStart: true)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let marker = harness.root.appendingPathComponent("worker.started")
        let client = PythonVisualGroundingClient(configuration: harness.configuration)
        let gate = Gate()
        let pending = Task {
            await gate.wait()
            try await client.prepare()
        }

        pending.cancel()
        await gate.open()
        do {
            try await pending.value
            XCTFail("A cancelled prewarm unexpectedly started the worker.")
        } catch is CancellationError {
            // Expected: prepare checks cancellation before spawning a child.
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        try await client.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let shutdownIssues = await client.shutdown()
        XCTAssertTrue(shutdownIssues.isEmpty)
    }

    func testPrepareCanRestartWorkerAfterSuspension() async throws {
        let harness = try makeHarness(script: Self.respondingWorker)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let client = PythonVisualGroundingClient(configuration: harness.configuration)

        try await client.prepare()
        let firstShutdownIssues = await client.shutdown()
        XCTAssertTrue(firstShutdownIssues.isEmpty)
        try await client.prepare()
        let decision = try await client.ground(VisualGroundingRequest(
            id: UUID(),
            png: Data([1]),
            width: 1,
            height: 1,
            target: "Test button"
        ))
        XCTAssertEqual(decision.point, VisualGroundingPoint(x: 0.25, y: 0.25))
        let secondShutdownIssues = await client.shutdown()
        XCTAssertTrue(secondShutdownIssues.isEmpty)
    }

    func testRoundTripRemovesOnlyOwnedScreenshotsAndCoalescesShutdown() async throws {
        let harness = try makeHarness(script: Self.respondingWorker)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let stale = harness.requests
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        let unrelated = harness.requests.appendingPathComponent("keep.txt")
        try Data([9]).write(to: stale)
        try Data("keep".utf8).write(to: unrelated)

        let client = PythonVisualGroundingClient(configuration: harness.configuration)
        let request = VisualGroundingRequest(
            id: UUID(),
            png: Data([1]),
            width: 1,
            height: 1,
            target: "Test button"
        )
        let decision = try await client.ground(request)

        XCTAssertEqual(decision.point, VisualGroundingPoint(x: 0.25, y: 0.25))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: harness.requests
                .appendingPathComponent(request.id.uuidString)
                .appendingPathExtension("png").path
        ))

        async let first = client.shutdown()
        async let second = client.shutdown()
        let results = await (first, second)
        XCTAssertEqual(results.0, results.1)
        XCTAssertTrue(results.0.isEmpty)
    }

    func testCancellationWhileWorkerStartsDoesNotHoldTheCallerUntilReady() async throws {
        let harness = try makeHarness(script: Self.slowStartingWorker)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let client = PythonVisualGroundingClient(configuration: harness.configuration)
        let clock = ContinuousClock()
        let started = clock.now
        let request = VisualGroundingRequest(
            id: UUID(),
            png: Data([1]),
            width: 1,
            height: 1,
            target: "Test button"
        )
        let pending = Task { try await client.ground(request) }
        try await Task.sleep(for: .milliseconds(100))
        pending.cancel()

        do {
            _ = try await pending.value
            XCTFail("Cancelled startup unexpectedly returned a grounding decision.")
        } catch is CancellationError {
            // Expected: caller cancellation removes only this readiness waiter.
        }
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
        let shutdownIssues = await client.shutdown()
        XCTAssertTrue(shutdownIssues.isEmpty)
    }

    func testFatalWorkerErrorIsNotReusedAndNextRequestStartsFreshWorker() async throws {
        let harness = try makeHarness(script: Self.failOnceWorker)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let client = PythonVisualGroundingClient(configuration: harness.configuration)
        let request = VisualGroundingRequest(
            id: UUID(),
            png: Data([1]),
            width: 1,
            height: 1,
            target: "Test button"
        )

        do {
            _ = try await client.ground(request)
            XCTFail("Expected the injected fatal worker error.")
        } catch {
            // Expected.
        }
        try await Task.sleep(for: .seconds(1))
        let retry = VisualGroundingRequest(
            id: UUID(),
            png: Data([1]),
            width: 1,
            height: 1,
            target: "Test button"
        )
        let decision = try await client.ground(retry)
        XCTAssertEqual(decision.point, VisualGroundingPoint(x: 0.25, y: 0.25))
        let shutdownIssues = await client.shutdown()
        XCTAssertTrue(shutdownIssues.isEmpty)
    }

    private struct Harness {
        let root: URL
        let requests: URL
        let configuration: VisualGroundingConfiguration
    }

    private func makeHarness(script: String, recordsStart: Bool = false) throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Computa-grounder-test-\(UUID().uuidString)",
                isDirectory: true
            )
        let models = root.appendingPathComponent("models", isDirectory: true)
        let requests = root.appendingPathComponent("requests", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        for name in ["goclick-base-4bit", "gui-owl-2b", "showui-2b-4bit"] {
            try FileManager.default.createDirectory(
                at: models.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false
            )
        }
        let worker = root.appendingPathComponent("worker.py")
        let startRecord = recordsStart
            ? "from pathlib import Path\nPath(__file__).with_suffix('.started').write_text('started')\n"
            : ""
        try Data((startRecord + script).utf8).write(to: worker)
        return Harness(
            root: root,
            requests: requests,
            configuration: VisualGroundingConfiguration(
                pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"),
                workerScript: worker,
                modelRoot: models,
                requestRoot: requests,
                warmupImage: nil,
                startupTimeout: .seconds(10),
                requestTimeout: .seconds(2)
            )
        )
    }

    private static let respondingWorker = #"""
import json
import sys

def emit(value):
    text = json.dumps(value) + "\n"
    for index in range(0, len(text), 3):
        sys.stdout.write(text[index:index + 3])
        sys.stdout.flush()

emit({
    "type": "ready",
    "protocol_version": 1,
    "method_version": "goclick-guiowl-showui-agreement-v2"
})
for line in sys.stdin:
    request = json.loads(line)
    emit({
        "id": request["id"],
        "ok": True,
        "point": {"x": 0.25, "y": 0.25},
        "method_version": "goclick-guiowl-showui-agreement-v2",
        "used_showui": False,
        "selected_pair": ["goclick", "gui_owl_2b"],
        "agreement_threshold_normalized_diagonal": 0.03,
        "initial_distance_normalized_diagonal": 0.0,
        "selected_distance_normalized_diagonal": 0.0,
        "model_points": {
            "goclick": {"x": 0.25, "y": 0.25},
            "gui_owl_2b": {"x": 0.25, "y": 0.25},
            "showui": None
        },
        "model_latency_ms": {"goclick": 1.0, "gui_owl_2b": 1.0, "showui": None},
        "latency_ms": 2.0,
        "image_width": 1,
        "image_height": 1
    })
"""#

    private static let slowStartingWorker = #"""
import json
import time

time.sleep(5)
print(json.dumps({
    "type": "ready",
    "protocol_version": 1,
    "method_version": "goclick-guiowl-showui-agreement-v2"
}), flush=True)
"""#

    private static let failOnceWorker = #"""
import json
from pathlib import Path
import sys

marker = Path(__file__).with_suffix(".started")
first = not marker.exists()
marker.write_text("started")
print(json.dumps({
    "type": "ready",
    "protocol_version": 1,
    "method_version": "goclick-guiowl-showui-agreement-v2"
}), flush=True)
request = json.loads(sys.stdin.readline())
if first:
    print(json.dumps({
        "id": request["id"],
        "ok": False,
        "error_code": "worker_error",
        "error": "injected fatal worker error"
    }), flush=True)
    raise SystemExit(1)
print(json.dumps({
    "id": request["id"],
    "ok": True,
    "point": {"x": 0.25, "y": 0.25},
    "method_version": "goclick-guiowl-showui-agreement-v2",
    "used_showui": False,
    "selected_pair": ["goclick", "gui_owl_2b"],
    "agreement_threshold_normalized_diagonal": 0.03,
    "initial_distance_normalized_diagonal": 0.0,
    "selected_distance_normalized_diagonal": 0.0,
    "model_points": {
        "goclick": {"x": 0.25, "y": 0.25},
        "gui_owl_2b": {"x": 0.25, "y": 0.25},
        "showui": None
    },
    "model_latency_ms": {"goclick": 1.0, "gui_owl_2b": 1.0, "showui": None},
    "latency_ms": 2.0,
    "image_width": 1,
    "image_height": 1
}), flush=True)
"""#
}

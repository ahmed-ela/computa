import Darwin
import Foundation
import XCTest
@testable import Mactopus

/// Serial opt-in: production AppState/App Server and owned MLX, no desktop
/// actions. Never stops any PID discovered by this test; the owner does cleanup.
@MainActor
final class HeadlessMLXModelSwitchLiveTests: XCTestCase {
    func testOwnedProcessRotatesFourNineFourWhilePreservingOneTask() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HEYDASH_LIVE_OWNED_MLX_SWITCH_TEST"] == "1",
            "Reserve the inference lane and set HEYDASH_LIVE_OWNED_MLX_SWITCH_TEST=1.")
        let models = ["lmstudio-community/Qwen3.5-4B-MLX-4bit",
                      "lmstudio-community/Qwen3.5-9B-MLX-4bit",
                      "lmstudio-community/Qwen3.5-4B-MLX-4bit"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MactopusMLXSwitch-\(UUID().uuidString)")
        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.codexHomePath = root.path
        let traceURL = root.appendingPathComponent("protocol.jsonl")
        configuration.protocolTracePath = traceURL.path
        let state = AppState(tasks: [], runtime: CodexAppServerRuntime(configuration: configuration),
                             preferences: isolatedTestPreferences())
        let events = Task { await state.startRuntime() }
        defer { events.cancel() }
        var nonces = [String]()
        var pids = [Int32]()
        print("HEYDASH_MLX_SWITCH_ARTIFACT_DIR=\(root.path) backend=headlessMLX")
        do {
            try await waitUntil(state: state) {
                if case .connected = state.connectionState { return true }
                return false
            }
            state.createTask()
            let taskID = try XCTUnwrap(state.selectedTaskID)
            for (index, model) in models.enumerated() {
                let resources = try FileManager.default.attributesOfFileSystem(forPath: root.path)
                let free = try XCTUnwrap(resources[.systemFreeSize] as? NSNumber).uint64Value
                guard free >= 1_536 * 1_024 * 1_024 else { throw Failure("Free disk below 1.5 GiB; no next inference started.") }
                XCTAssertTrue(state.setTaskModel(model, taskID: taskID))
                let marker = "HEYDASH_MODEL_ROTATION_\(index)_OK"
                guard await state.submit(prompt: "Reply with exactly \(marker). Do not use tools.", toTaskID: taskID) else {
                    throw Failure("Model-switch prompt was not submitted.")
                }
                try await waitUntil(state: state) {
                    state.tasks.first(where: { $0.id == taskID })?.status == .completed
                }
                let task = try XCTUnwrap(state.tasks.first(where: { $0.id == taskID }))
                XCTAssertEqual(task.model, model)
                XCTAssertEqual(task.entries.last(where: { $0.kind == .assistant })?.body
                    .trimmingCharacters(in: .whitespacesAndNewlines), marker)
                XCTAssertTrue(task.entries.compactMap(\.toolEvent).isEmpty)
                let health = try await readHealth()
                XCTAssertEqual(health["selected_model"] as? String, model)
                let nonce = try XCTUnwrap(health["heydash_instance"] as? String)
                XCTAssertNotNil(UUID(uuidString: nonce))
                let pid = try listeningProcessID()
                if let previous = pids.last {
                    XCTAssertNotEqual(pid, previous)
                    XCTAssertEqual(Darwin.kill(previous, 0), -1, "Old weights process must be gone before replacement inference")
                    XCTAssertEqual(errno, ESRCH)
                }
                nonces.append(nonce)
                pids.append(pid)
                print("modelSwitchStep=\(index) model=\(model) ownedPID=\(pid) instance=\(nonce)")
            }
            XCTAssertEqual(Set(nonces).count, 3)
            XCTAssertEqual(Set(pids).count, 3)
            let trace = try AppServerWireTrace.load(traceURL)
            XCTAssertTrue(trace.parseFailures.isEmpty)
            XCTAssertEqual(trace.messages.filter { $0.direction == .clientToServer && $0.method == "initialize" }.count, 1)
            XCTAssertEqual(trace.messages.filter { $0.direction == .clientToServer && $0.method == "thread/start" }.count, 1)
            let starts = trace.messages.filter { $0.direction == .clientToServer && $0.method == "turn/start" }
            XCTAssertEqual(starts.compactMap { ($0.object["params"] as? [String: Any])?["model"] as? String }, models)
            let threads = starts.compactMap { ($0.object["params"] as? [String: Any])?["threadId"] as? String }
            XCTAssertEqual(threads.count, 3)
            XCTAssertEqual(Set(threads).count, 1, "Rotation must not replace the App Server conversation")
            let report = await state.shutdownRuntime()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            for pid in pids {
                XCTAssertEqual(Darwin.kill(pid, 0), -1)
                XCTAssertEqual(errno, ESRCH)
            }
            print("ownedModelRotationVerified=true sameThread=\(threads.first ?? "missing") ownedShutdown=\(report.succeeded)")
        } catch {
            let report = await state.shutdownRuntime()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            throw error
        }
    }

    private func waitUntil(state: AppState, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline {
            if condition() { return }
            if case .failed(let message) = state.connectionState { throw Failure(message) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("Timed out waiting for owned model-switch gate; inspect private protocol evidence.")
    }

    private func readHealth() async throws -> [String: Any] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:1237/health")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func listeningProcessID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:1237", "-sTCP:LISTEN", "-t"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let identifiers = Set(String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) })
        XCTAssertEqual(identifiers.count, 1)
        return try XCTUnwrap(identifiers.first)
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

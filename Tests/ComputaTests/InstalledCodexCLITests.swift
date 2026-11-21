import Foundation
import XCTest
@testable import Computa

@MainActor
final class InstalledCodexCLITests: XCTestCase {
    func testPickerLoadsEveryVisibleModelAcrossPagesAndRejectsRepeatedCursor() async throws {
        typealias Page = InstalledCodexCLI.Page
        let one = Page.Model(model: "one", displayName: "First", description: nil, hidden: false)
        let two = Page.Model(model: "two", displayName: "Second", description: nil, hidden: false)
        let hidden = Page.Model(model: "hidden", displayName: "Hidden", description: nil, hidden: true)
        let choices = try await InstalledCodexCLI.models { cursor in
            cursor == nil ? Page(data: [one, hidden], nextCursor: "page2") : Page(data: [one, two], nextCursor: nil)
        }
        XCTAssertEqual(choices.map(\.id), ["cli/codex/model/one", "cli/codex/model/two"])
        XCTAssertEqual(choices.map(\.label), ["Codex CLI / First", "Codex CLI / Second"])
        do {
            _ = try await InstalledCodexCLI.models { _ in Page(data: [], nextCursor: "again") }
            XCTFail("Repeated cursor accepted")
        } catch InstalledCodexCLI.Failure.invalidCatalog {}
    }

    func testEmptyCLIProfileShowsLoginAndNoSelectableModels() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["COMPUTA_LIVE_SIGNED_OUT_CLI"] == "1" && env["CODEX_HOME"] != nil,
                          "Run with an empty, temporary CODEX_HOME and the signed-out test opt-in.")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaCLISignedOut-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = CodexAppServerRuntime.Configuration.localQwen
        config.codexHomePath = root.path
        config.workspacePath = root.appendingPathComponent("Workspace").path
        let runtime = SelectableCodexRuntime(configuration: config)
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        for _ in 0..<2 {
            await state.refreshInstalledCLIModels()
            let snapshot = WebUISnapshot(state: state)
            let setup = snapshot.providerSetups.first { $0.route == InstalledCodexCLI.route }
            XCTAssertEqual(setup?.connected, false)
            XCTAssertEqual(setup?.detail, InstalledCodexCLI.Failure.signedOut.localizedDescription)
            XCTAssertFalse(snapshot.modelOptions.contains { InstalledCodexCLI.slug($0.id) != nil })
        }
        _ = await runtime.shutdown()
    }

    func testSignedInCLIThroughComputaAndRestoredHistory() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMPUTA_LIVE_CODEX_CLI"] == "1",
                          "Requires an installed, signed-in Codex CLI and sends two harmless test messages.")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaCLILive-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = CodexAppServerRuntime.Configuration.localQwen
        config.codexHomePath = root.path
        config.workspacePath = root.appendingPathComponent("Workspace").path
        let runtime = SelectableCodexRuntime(configuration: config)
        let state = AppState(tasks: [], runtime: runtime, preferences: isolatedTestPreferences())
        state.startRuntimeIfNeeded()
        do {
            try await waitUntil {
                if case .failed(let message) = state.connectionState { throw NSError(domain: message, code: 1) }
                if case .connected = state.connectionState { return true }
                return false
            }
            await state.refreshInstalledCLIModels()
            let snapshot = WebUISnapshot(state: state)
            XCTAssertTrue(snapshot.providerSetups.contains { $0.route == "cli/codex" && $0.connected }, state.installedCLIError ?? "")
            let options = snapshot.modelOptions.filter { InstalledCodexCLI.slug($0.id) != nil }
            let model = try XCTUnwrap(options.first)
            state.createTask()
            let id = try XCTUnwrap(state.selectedTaskID)
            XCTAssertTrue(state.setTaskModel(model.id, taskID: id))
            let marker = "COMPUTA-" + UUID().uuidString.prefix(8)
            let sent = await state.submit(prompt: "Reply with exactly " + marker + " and use no tools.", toTaskID: id)
            XCTAssertTrue(sent, state.selectedTask?.entries.last?.body ?? "")
            guard sent else { throw InstalledCodexCLI.Failure.unavailable }
            try await waitUntil {
                let task = state.selectedTask
                if task?.status == .failed { throw NSError(domain: task?.entries.last?.body ?? "CLI turn failed", code: 2) }
                return task?.status == .completed && task?.entries.contains { $0.kind == .assistant && $0.body.contains(marker) } == true
            }
            let thread = try XCTUnwrap(state.selectedTask?.runtimeThreadID)
            print("Computa CLI live: \(options.count) models; \(model.label); reply \(marker)")
            let next = try XCTUnwrap(options.dropFirst().first)
            XCTAssertTrue(state.setTaskModel(next.id, taskID: id))
            let secondMarker = "SWITCH-" + UUID().uuidString.prefix(8)
            let nextSent = await state.submit(prompt: "Reply with exactly " + secondMarker + " and use no tools.", toTaskID: id)
            guard nextSent else { throw NSError(domain: state.selectedTask?.entries.last?.body ?? "Second submit failed", code: 4) }
            try await waitUntil {
                if state.selectedTask?.status == .failed { throw NSError(domain: state.selectedTask?.entries.last?.body ?? "Second turn failed", code: 5) }
                return state.selectedTask?.status == .completed && state.selectedTask?.entries.contains { $0.kind == .assistant && $0.body.contains(secondMarker) } == true
            }
            print("Computa CLI switch: \(next.label); reply \(secondMarker)")
            XCTAssertEqual(state.selectedTask?.runtimeThreadID, thread)
            let stopped = await state.shutdownRuntime()
            XCTAssertTrue(stopped.succeeded, stopped.issues.joined(separator: ", "))
            let reopened = SelectableCodexRuntime(configuration: config)
            do {
                let chats = try await reopened.loadTasks()
                XCTAssertEqual(chats.map(\.id), [thread])
                XCTAssertEqual(chats.first?.model, next.id)
                XCTAssertTrue(chats.first?.entries.contains { $0.kind == .assistant && $0.body.contains(secondMarker) } == true)
                XCTAssertTrue(chats.first?.entries.contains { $0.kind == .assistant && $0.body.contains(marker) } == true)
            } catch { _ = await reopened.shutdown(); throw error }
            _ = await reopened.shutdown()
        } catch { _ = await state.shutdownRuntime(); throw error }
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(70))
        while try !condition() {
            guard ContinuousClock.now < limit else { throw NSError(domain: "Timed out waiting for Computa", code: 3) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

import AppKit
import AutomationCore
import Foundation
import XCTest
@testable import LocalCodex

/// Opt-in production-runtime gate for the full V2 Chrome capture path. Unlike
/// DriverLatencyLiveTests, this includes Qwen tool selection, App Server
/// dispatch, exact-open approval, focused-window binding, screenshot and AX.
@MainActor
final class ChromeCaptureV2LiveTests: XCTestCase {
    private let bundleID = "com.google.Chrome"

    private final class ApprovalAudit {
        var approvedOpen = false
        var handled = Set<String>()
        var unexpected = [String]()
    }

    private struct GateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func testProductionRuntimeCapturesBoundChromeWindow() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_CHROME_CAPTURE_V2_TEST"] == "1",
            "Set LOCALCODEX_LIVE_CHROME_CAPTURE_V2_TEST=1 for this live gate."
        )
        _ = NSApplication.shared
        let permissions = PermissionInspector().current()
        try XCTSkipUnless(
            permissions.accessibility == .granted && permissions.screenRecording == .granted,
            "Chrome capture requires Accessibility and Screen Recording."
        )
        try XCTSkipUnless(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil,
            "Chrome is not installed."
        )
        let modelID = ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_MODEL_ID"]
            ?? "lmstudio-community/Qwen3.5-4B-MLX-4bit"
        guard LocalModelCatalog.option(for: modelID) != nil else {
            throw GateError(message: "Model is not in the local selector: \(modelID)")
        }
        let pageURL = "https://example.com/?localcodex_capture_id=\(UUID().uuidString)"
        let token = "LOCALCODEX_CHROME_CAPTURE_OK_"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")

        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.codexHomePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCodexChromeCapture-\(UUID().uuidString)", isDirectory: true)
            .path
        let wireURL = URL(fileURLWithPath: configuration.codexHomePath, isDirectory: true)
            .appendingPathComponent("app-server-wire.jsonl")
        configuration.protocolTracePath = wireURL.path
        let state = AppState(tasks: [], runtime: CodexAppServerRuntime(configuration: configuration))
        let runtimeTask = Task { await state.startRuntime() }
        defer { runtimeTask.cancel() }
        try await waitForConnection(state)

        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        XCTAssertTrue(state.setTaskModel(modelID, taskID: taskID))
        let audit = ApprovalAudit()
        let approvals = approveOnlyExactOpen(
            state: state, taskID: taskID, pageURL: pageURL, audit: audit
        )
        defer { approvals.cancel() }

        let submitted = await state.submit(
            prompt: """
            Use only these computer tools: call computer_v2_open exactly once with {"bundle_id":"com.google.Chrome","url":"\(pageURL)"}. Then call computer_v2_capture with {"include_accessibility":true}. If the synchronized AX snapshot does not yet show the Example Domain heading, retry computer_v2_capture with the same arguments up to two more times. Read the returned WINDOW_CAPTURE metadata, PNG image, and synchronized AX snapshot. After seeing the Example Domain heading, reply with exactly \(token). Do not click, type, navigate elsewhere, or use any other tool. If capture fails, report failure rather than the token.
            """,
            toTaskID: taskID
        )
        guard submitted else { throw GateError(message: "The Chrome capture prompt was not submitted.") }

        let completed = try await waitForCompletion(state, taskID: taskID, audit: audit)
        XCTAssertTrue(audit.approvedOpen)
        XCTAssertTrue(audit.unexpected.isEmpty, audit.unexpected.joined(separator: "\n"))
        XCTAssertEqual(completed.model, modelID)

        let calls = try completed.entries.compactMap { entry -> (
            name: String, arguments: [String: Any], status: ToolRunStatus,
            content: [[String: Any]]
        )? in
            guard let event = entry.toolEvent else { return nil }
            guard event.name.hasPrefix("computer_v2_"),
                  let transcript = object(event.input),
                  transcript["tool"] as? String == event.name,
                  let arguments = object(transcript["arguments"]),
                  let content = transcript["contentItems"] as? [[String: Any]] else {
                throw GateError(message: "Malformed V2 tool event: \(event.name)")
            }
            return (event.name, arguments, event.status, content)
        }
        guard (2 ... 4).contains(calls.count),
              calls.first?.name == ComputerV2ToolContract.Tool.open.rawValue,
              calls.dropFirst().allSatisfy({ $0.name == ComputerV2ToolContract.Tool.capture.rawValue }),
              calls.allSatisfy({ $0.status == .succeeded }) else {
            throw GateError(message: "Unexpected or unsuccessful tool sequence: \(calls.map(\.name))")
        }
        XCTAssertEqual(calls[0].arguments["bundle_id"] as? String, bundleID)
        XCTAssertEqual(calls[0].arguments["url"] as? String, pageURL)
        for capture in calls.dropFirst() {
            XCTAssertEqual(capture.arguments["include_accessibility"] as? Bool, true)
            let text = capture.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            XCTAssertTrue(text.contains("WINDOW_CAPTURE capture_id="))
            XCTAssertTrue(text.contains("image_width="))
            XCTAssertTrue(text.contains("SYNCHRONIZED_AX"))
            XCTAssertTrue(text.contains("AXSNAPSHOT id="))
            XCTAssertTrue(capture.content.contains {
                $0["type"] as? String == "inputImage"
                    && ($0["imageUrl"] as? String)?.hasPrefix("data:image/png;base64,") == true
            })
        }
        let finalText = calls.last?.content.compactMap { $0["text"] as? String }
            .joined(separator: "\n") ?? ""
        XCTAssertTrue(finalText.contains("Example Domain"))
        XCTAssertEqual(
            completed.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            token
        )

        let trace = try await waitForWireTrace(wireURL)
        XCTAssertTrue(trace.parseFailures.isEmpty, trace.parseFailures.joined(separator: "\n"))
        XCTAssertTrue(trace.messages.contains { message in
            message.direction == .serverToClient
                && message.method == "item/tool/call"
                && (message.object["params"] as? [String: Any])?["tool"] as? String
                    == ComputerV2ToolContract.Tool.capture.rawValue
        })
    }

    private func approveOnlyExactOpen(
        state: AppState,
        taskID: AgentTask.ID,
        pageURL: String,
        audit: ApprovalAudit
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                for request in state.pendingApprovals where !audit.handled.contains(request.id) {
                    audit.handled.insert(request.id)
                    let details = object(request.details)
                    let allow = !audit.approvedOpen
                        && request.taskID == taskID
                        && request.kind == .computerUse
                        && request.title == "Allow an application action?"
                        && request.summary == "Open \(bundleID) at \(pageURL)"
                        && details?["bundle_id"] as? String == bundleID
                        && details?["url"] as? String == pageURL
                        && Set(details?.keys.map { $0 } ?? []) == ["bundle_id", "url"]
                    if allow { audit.approvedOpen = true }
                    else { audit.unexpected.append("Unexpected approval: \(request.summary)") }
                    await state.resolveApproval(request, approved: allow)
                    if !allow { return }
                }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
        }
    }

    private func waitForConnection(_ state: AppState) async throws {
        for _ in 0 ..< 80 {
            switch state.connectionState {
            case .connected: return
            case .failed(let message): throw GateError(message: "Runtime failed: \(message)")
            case .connecting, .disconnected: break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GateError(message: "Timed out connecting to App Server.")
    }

    private func waitForCompletion(
        _ state: AppState,
        taskID: AgentTask.ID,
        audit: ApprovalAudit
    ) async throws -> AgentTask {
        for _ in 0 ..< 480 {
            if let unexpected = audit.unexpected.first { throw GateError(message: unexpected) }
            if case .failed(let message) = state.connectionState {
                throw GateError(message: "App Server failed: \(message)")
            }
            guard let task = state.tasks.first(where: { $0.id == taskID }) else {
                throw GateError(message: "The Chrome capture task disappeared.")
            }
            if task.status == .completed { return task }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GateError(message: "Timed out waiting for Chrome capture turn.")
    }

    private func waitForWireTrace(_ url: URL) async throws -> AppServerWireTrace {
        for _ in 0 ..< 20 {
            if let trace = try? AppServerWireTrace.load(url),
               trace.messages.contains(where: { $0.method == "item/completed" }) {
                return trace
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GateError(message: "The App Server wire trace was unavailable.")
    }

    private func object(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let string = value as? String, let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

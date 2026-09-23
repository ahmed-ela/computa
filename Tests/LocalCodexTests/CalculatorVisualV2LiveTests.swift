import AppKit
import AutomationCore
import Foundation
import XCTest
@testable import LocalCodex

/// Opt-in, non-browser visual computer-use gate. It deliberately refuses every
/// action except opening Calculator and clicking its independently measured
/// digit-one button. This test is never run by the ordinary test suite.
@MainActor
final class CalculatorVisualV2LiveTests: XCTestCase {
    private let bundleID = "com.apple.calculator"
    private let expectedTools = [
        ComputerV2ToolContract.Tool.open.rawValue,
        ComputerV2ToolContract.Tool.capture.rawValue,
        ComputerV2ToolContract.Tool.click.rawValue,
        ComputerV2ToolContract.Tool.snapshot.rawValue,
    ]

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct CaptureMetadata {
        let id: UUID
        let width: Int
        let height: Int
    }

    private struct ToolCall {
        let name: String
        let arguments: [String: Any]
        let status: ToolRunStatus
        let content: [[String: Any]]

        var text: String {
            content.filter { $0["type"] as? String == "inputText" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        }
    }

    private final class ApprovalAudit {
        var approved = [String]()
        var denied = [String]()
        var handled = Set<String>()
        var processID: Int32?
        var capture: CaptureMetadata?
        var approvedPoint: ScreenPoint?
        var beforeDisplay: String?
    }

    func testModelClicksCalculatorDigitOneFromDisplayCapture() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_VISUAL_CALCULATOR_TEST"] == "1",
            "Set LOCALCODEX_LIVE_VISUAL_CALCULATOR_TEST=1 for this opt-in live gate."
        )
        let permissions = PermissionInspector().current()
        guard permissions.accessibility == .granted,
              permissions.screenRecording == .granted else {
            throw Failure(message: "The opted-in visual gate requires Accessibility and Screen Recording permissions.")
        }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            throw Failure(message: "The opted-in visual gate requires Calculator on this Mac.")
        }

        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.codexHomePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCodexVisualCalculator-\(UUID().uuidString)", isDirectory: true)
            .path
        let wirePath = URL(fileURLWithPath: configuration.codexHomePath, isDirectory: true)
            .appendingPathComponent("app-server-wire.jsonl")
        configuration.protocolTracePath = wirePath.path
        let state = AppState(tasks: [], runtime: CodexAppServerRuntime(configuration: configuration))
        let runtimeTask = Task { await state.startRuntime() }
        defer { runtimeTask.cancel() }
        try await waitForConnection(state)

        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        let modelID = ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_MODEL_ID"]
            ?? LocalModelCatalog.defaultModelID
        guard LocalModelCatalog.option(for: modelID) != nil,
              state.setTaskModel(modelID, taskID: taskID) else {
            throw Failure(message: "The requested local model is not in the model selector: \(modelID)")
        }
        let token = "LOCALCODEX_CALCULATOR_VISUAL_OK_"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let audit = ApprovalAudit()
        let approvalTask = approvalLoop(state: state, taskID: taskID, audit: audit)
        defer { approvalTask.cancel() }

        let submitted = await state.submit(
            prompt: """
            Use exactly four computer tools in this order: computer_v2_open with {"bundle_id":"com.apple.calculator"}; computer_v2_capture with {}; computer_v2_click once at the center of the visible Calculator digit 1 button, using x and y in the returned image pixels and copying its capture_id exactly; computer_v2_snapshot with {}. Do not click any other control, use a process ID, or use another tool. Read the post-click snapshot, then reply with exactly \(token). If any step fails, say so instead of claiming success.
            """,
            toTaskID: taskID
        )
        guard submitted else {
            throw Failure(message: "The visual Calculator prompt was not submitted. \(diagnostics(state))")
        }
        let completed = try await waitForCompletion(state, taskID: taskID, audit: audit)
        XCTAssertEqual(completed.model, modelID)
        XCTAssertEqual(audit.approved, ["open", "click"])
        XCTAssertTrue(audit.denied.isEmpty, audit.denied.joined(separator: "\n"))
        let calls = try toolCalls(completed)
        XCTAssertEqual(calls.map(\.name), expectedTools)
        XCTAssertTrue(calls.allSatisfy { $0.status == .succeeded })
        XCTAssertEqual(calls[0].arguments["bundle_id"] as? String, bundleID)
        XCTAssertEqual(Set(calls[0].arguments.keys), ["bundle_id"])
        XCTAssertTrue(calls[1].arguments.isEmpty)
        XCTAssertEqual(Set(calls[2].arguments.keys), ["capture_id", "x", "y"])
        XCTAssertTrue(calls[3].arguments.isEmpty)
        XCTAssertEqual(calls[2].arguments["capture_id"] as? String, audit.capture?.id.uuidString)
        XCTAssertEqual(
            completed.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            token
        )

        let pid = try XCTUnwrap(audit.processID)
        let display = try calculatorDisplayValue(processID: pid)
        let before = try XCTUnwrap(audit.beforeDisplay)
        let expectedDisplay = before == "0" ? "1" : before + "1"
        XCTAssertEqual(
            display, expectedDisplay,
            "The independent Calculator AX display did not make the expected integer-entry transition \(before) -> \(expectedDisplay). If Calculator was in result mode, this gate is inconclusive; no reset action is performed."
        )
        try await verifyRollout(
            in: configuration.codexHomePath,
            expectedPID: pid,
            expectedCapture: try XCTUnwrap(audit.capture),
            completionToken: token
        )
        try await verifyWire(
            at: wirePath,
            expectedModelID: modelID,
            expectedCapture: try XCTUnwrap(audit.capture)
        )
    }

    private func approvalLoop(
        state: AppState,
        taskID: AgentTask.ID,
        audit: ApprovalAudit
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                for request in state.pendingApprovals where !audit.handled.contains(request.id) {
                    audit.handled.insert(request.id)
                    let decision: (Bool, String)
                    do {
                        if audit.approved.isEmpty {
                            decision = (try allowOpen(request, state: state, taskID: taskID), "open")
                        } else if audit.approved == ["open"] {
                            decision = (try allowDigitOneClick(
                                request, state: state, taskID: taskID, audit: audit
                            ), "click")
                        } else {
                            decision = (false, "No further mutation is permitted")
                        }
                    } catch {
                        decision = (false, error.localizedDescription)
                    }
                    await state.resolveApproval(request, approved: decision.0)
                    if decision.0 {
                        audit.approved.append(decision.1)
                    } else {
                        audit.denied.append("Denied \(request.summary): \(decision.1)")
                    }
                    if !decision.0 { return }
                }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
        }
    }

    private func allowOpen(
        _ request: ActionApprovalRequest,
        state: AppState,
        taskID: AgentTask.ID
    ) throws -> Bool {
        guard request.taskID == taskID,
              request.kind == .computerUse,
              request.title == "Allow an application action?",
              request.summary == "Launch or activate \(bundleID)",
              let details = object(request.details),
              Set(details.keys) == ["bundle_id"],
              details["bundle_id"] as? String == bundleID,
              let task = state.tasks.first(where: { $0.id == taskID }),
              try toolCalls(task).filter({ $0.status == .succeeded }).isEmpty
        else { return false }
        return true
    }

    private func allowDigitOneClick(
        _ request: ActionApprovalRequest,
        state: AppState,
        taskID: AgentTask.ID,
        audit: ApprovalAudit
    ) throws -> Bool {
        guard request.taskID == taskID,
              request.kind == .computerUse,
              request.title == "Allow computer input?",
              let task = state.tasks.first(where: { $0.id == taskID })
        else { return false }
        let calls = try toolCalls(task)
        guard calls.count >= 2,
              calls[0].name == expectedTools[0], calls[0].status == .succeeded,
              calls[1].name == expectedTools[1], calls[1].status == .succeeded,
              calls.dropFirst(2).allSatisfy({ $0.name == expectedTools[2] })
        else { return false }
        guard let pid = processIdentifier(calls[0].text),
              let running = NSRunningApplication(processIdentifier: pid),
              running.bundleIdentifier == bundleID,
              !running.isTerminated,
              let capture = captureMetadata(calls[1].text),
              calls[1].content.contains(where: {
                  $0["type"] as? String == "inputImage"
                      && ($0["imageUrl"] as? String)?.hasPrefix("data:image/png;base64,") == true
              })
        else { return false }
        guard let details = object(request.details),
              Set(details.keys) == ["model_arguments", "resolved_target", "resolved_action"],
              let modelArguments = details["model_arguments"] as? [String: Any],
              Set(modelArguments.keys) == ["capture_id", "x", "y"],
              let modelCaptureID = modelArguments["capture_id"] as? String,
              UUID(uuidString: modelCaptureID) == capture.id,
              let imageX = finiteNumber(modelArguments["x"]),
              let imageY = finiteNumber(modelArguments["y"]),
              imageX >= 0, imageX < Double(capture.width),
              imageY >= 0, imageY < Double(capture.height),
              let resolved = details["resolved_target"] as? [String: Any],
              Set(resolved.keys) == ["bundle_id", "process_id"],
              resolved["bundle_id"] as? String == bundleID,
              (resolved["process_id"] as? NSNumber)?.int32Value == pid,
              let action = details["resolved_action"] as? String,
              action == request.summary,
              let point = clickPoint(action),
              let buttonFrame = try digitOneFrame(processID: pid),
              let beforeDisplay = try calculatorDisplayValue(processID: pid),
              beforeDisplay.count < 15
        else { return false }

        guard point.x > buttonFrame.x,
              point.x < buttonFrame.x + buttonFrame.width,
              point.y > buttonFrame.y,
              point.y < buttonFrame.y + buttonFrame.height else {
            throw Failure(
                message: "Resolved click (\(point.x), \(point.y)) is outside digit-1 AX frame "
                    + "(\(buttonFrame.x), \(buttonFrame.y), \(buttonFrame.width), \(buttonFrame.height))."
            )
        }

        audit.processID = pid
        audit.capture = capture
        audit.approvedPoint = point
        audit.beforeDisplay = beforeDisplay
        return true
    }

    private func accessibilitySnapshot(processID: Int32) throws -> AccessibilityTreeSnapshot {
        guard let running = NSRunningApplication(processIdentifier: processID),
              running.bundleIdentifier == bundleID, !running.isTerminated else {
            throw Failure(message: "The bound Calculator process is no longer running.")
        }
        let limits = try AccessibilityTreeLimits(
            maxDepth: 16, maxElements: 1_000, maxChildrenPerElement: 200,
            maxActionsPerElement: 32, maxTextLength: 1_024
        )
        return try AccessibilitySession(
            processIdentifier: processID,
            bundleIdentifier: bundleID,
            applicationName: running.localizedName
        ).snapshot(limits: limits)
    }

    private func digitOneFrame(processID: Int32) throws -> WindowFrame? {
        let buttons = try accessibilitySnapshot(processID: processID).elements.filter { element in
            element.role == "AXButton"
                && [element.title, element.elementDescription, element.identifier]
                    .contains(where: { $0 == "1" })
                && element.isEnabled != false
                && element.frame != nil
        }
        return buttons.count == 1 ? buttons[0].frame : nil
    }

    /// Use only non-button AX display text. Ambiguous numeric elements fail
    /// closed so a digit-one button label cannot masquerade as the result.
    private func calculatorDisplayValue(processID: Int32) throws -> String? {
        let elements = try accessibilitySnapshot(processID: processID).elements.filter {
            $0.role != "AXButton" && ["AXTextField", "AXStaticText", "AXValueIndicator"].contains($0.role ?? "")
        }
        let numeric = elements.compactMap { element -> (String, Bool)? in
            let raw = (element.value ?? element.title ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = raw.replacingOccurrences(of: ",", with: "")
            guard !normalized.isEmpty,
                  normalized.unicodeScalars.allSatisfy({ (48...57).contains($0.value) })
            else { return nil }
            let metadata = [element.title, element.elementDescription, element.identifier, element.help]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            let looksLikeDisplay = metadata.contains("display") || metadata.contains("result")
                || element.role == "AXTextField"
            return (normalized, looksLikeDisplay)
        }
        let preferred = numeric.filter(\.1).map(\.0)
        if preferred.count == 1 { return preferred[0] }
        return numeric.count == 1 ? numeric[0].0 : nil
    }

    private func toolCalls(_ task: AgentTask) throws -> [ToolCall] {
        try task.entries.compactMap { entry in
            guard let event = entry.toolEvent else { return nil }
            guard event.name.hasPrefix("computer_v2_") else {
                throw Failure(message: "Unexpected non-V2 tool: \(event.name)")
            }
            guard let item = object(event.input),
                  item["tool"] as? String == event.name,
                  let arguments = object(item["arguments"])
            else { throw Failure(message: "Malformed tool transcript: \(event.name)") }
            return ToolCall(
                name: event.name,
                arguments: arguments,
                status: event.status,
                content: item["contentItems"] as? [[String: Any]] ?? []
            )
        }
    }

    private func processIdentifier(_ text: String) -> Int32? {
        guard let match = firstCapture(#""processIdentifier"\s*:\s*(\d+)"#, in: text),
              let pid = Int32(match) else { return nil }
        return pid
    }

    private func captureMetadata(_ text: String) -> CaptureMetadata? {
        guard let idText = firstCapture(#"capture_id=([0-9A-Fa-f-]{36})"#, in: text),
              let id = UUID(uuidString: idText),
              let widthText = firstCapture(#"image_width=(\d+)"#, in: text),
              let heightText = firstCapture(#"image_height=(\d+)"#, in: text),
              let width = Int(widthText), let height = Int(heightText),
              width > 0, height > 0,
              text.contains("coordinate_space=image_pixels")
        else { return nil }
        return CaptureMetadata(id: id, width: width, height: height)
    }

    private func clickPoint(_ summary: String) -> ScreenPoint? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^Click at \((-?(?:\d+(?:\.\d*)?|\.\d+)), (-?(?:\d+(?:\.\d*)?|\.\d+))\)$"#
        ), let match = regex.firstMatch(
            in: summary,
            range: NSRange(summary.startIndex..., in: summary)
        ), match.numberOfRanges == 3,
        let xRange = Range(match.range(at: 1), in: summary),
        let yRange = Range(match.range(at: 2), in: summary),
        let x = Double(summary[xRange]), let y = Double(summary[yRange]),
        x.isFinite, y.isFinite else { return nil }
        return ScreenPoint(x: x, y: y)
    }

    private func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private func object(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let text = value as? String,
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func waitForConnection(_ state: AppState) async throws {
        for _ in 0..<80 {
            switch state.connectionState {
            case .connected: return
            case .failed(let message): throw Failure(message: "Runtime connection failed: \(message)")
            case .connecting, .disconnected: break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure(message: "Timed out connecting to the local runtime.")
    }

    private func waitForCompletion(
        _ state: AppState,
        taskID: AgentTask.ID,
        audit: ApprovalAudit
    ) async throws -> AgentTask {
        for _ in 0..<3_600 {
            if let denied = audit.denied.first {
                throw Failure(message: "Unexpected or unsafe approval: \(denied). \(diagnostics(state))")
            }
            if case .failed(let message) = state.connectionState {
                throw Failure(message: "Runtime failed: \(message). \(diagnostics(state))")
            }
            guard let task = state.tasks.first(where: { $0.id == taskID }) else {
                throw Failure(message: "The Calculator task disappeared.")
            }
            if task.status == .completed { return task }
            if task.status == .waiting,
               task.entries.contains(where: {
                   $0.kind == .system && ["Agent error", "Prompt was not delivered"].contains($0.title)
               }) {
                throw Failure(message: "The Calculator turn failed. \(diagnostics(state))")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure(message: "Timed out waiting for Calculator. \(diagnostics(state))")
    }

    private func diagnostics(_ state: AppState) -> String {
        state.tasks.map { task in
            "\(task.id)=\(task.status.rawValue)["
                + task.entries.map { "\($0.kind.rawValue):\($0.body)" }.joined(separator: " | ")
                + "]"
        }.joined(separator: "; ")
    }

    private func verifyRollout(
        in home: String,
        expectedPID: Int32,
        expectedCapture: CaptureMetadata,
        completionToken: String
    ) async throws {
        var lastFailure = "Rollout has not appeared."
        for _ in 0..<80 {
            do {
                let trace = try RolloutPrimitiveTrace.loadLatest(in: home)
                if let failure = rolloutFailure(
                    trace, pid: expectedPID, capture: expectedCapture, token: completionToken
                ) {
                    lastFailure = failure
                } else { return }
            } catch { lastFailure = error.localizedDescription }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure(message: "Calculator rollout primitive did not converge: \(lastFailure)")
    }

    private func rolloutFailure(
        _ trace: RolloutPrimitiveTrace,
        pid: Int32,
        capture: CaptureMetadata,
        token: String
    ) -> String? {
        guard trace.parseFailures.isEmpty else { return "Malformed rollout JSONL" }
        let names = trace.dynamicTools.compactMap { $0["name"] as? String }
        let expectedNames = ComputerV2ToolContract.Tool.allCases.map(\.rawValue)
        guard names.count == expectedNames.count,
              Set(names) == Set(expectedNames),
              trace.functionCalls.map(\.name) == expectedTools else {
            return "V2 tool registration or function-call order did not match"
        }
        let calls = trace.functionCalls
        guard Set(calls.map(\.callID)).count == calls.count,
              trace.functionCallOutputs.map(\.callID) == calls.map(\.callID),
              calls[0].arguments["bundle_id"] as? String == bundleID,
              Set(calls[0].arguments.keys) == ["bundle_id"],
              calls[1].arguments.isEmpty,
              Set(calls[2].arguments.keys) == ["capture_id", "x", "y"],
              calls[2].arguments["capture_id"] as? String == capture.id.uuidString,
              calls[3].arguments.isEmpty,
              let openOutput = trace.output(for: calls[0].callID) as? String,
              processIdentifier(openOutput) == pid,
              let captureOutput = trace.output(for: calls[1].callID) as? [[String: Any]],
              captureOutput.contains(where: {
                  $0["type"] as? String == "input_image"
                      && ($0["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true
              }),
              let snapshotOutput = trace.output(for: calls[3].callID) as? String,
              snapshotOutput.contains("AXSNAPSHOT id="),
              snapshotOutput.contains("pid=\(pid) "),
              snapshotOutput.contains("bundle=\"\(bundleID)\"")
        else { return "Function arguments, output IDs, screenshot, or bound identity changed" }
        let final = trace.assistantMessages.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.last(where: { !$0.isEmpty })
        return final == token ? nil : "Final rollout text did not match the completion token"
    }

    private func verifyWire(
        at url: URL,
        expectedModelID: String,
        expectedCapture: CaptureMetadata
    ) async throws {
        var lastFailure = "Wire trace has not appeared."
        for _ in 0..<80 {
            do {
                let trace = try AppServerWireTrace.load(url)
                if let failure = wireFailure(
                    trace, modelID: expectedModelID, capture: expectedCapture
                ) { lastFailure = failure } else { return }
            } catch { lastFailure = error.localizedDescription }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure(message: "Calculator raw App Server trace did not converge: \(lastFailure)")
    }

    private func wireFailure(
        _ trace: AppServerWireTrace,
        modelID: String,
        capture: CaptureMetadata
    ) -> String? {
        guard !trace.messages.isEmpty,
              trace.parseFailures.isEmpty,
              trace.messages.map(\.sequence) == Array(1...trace.messages.count),
              trace.messages.allSatisfy({
                  $0.object["jsonrpc"] == nil && $0.wireData.last == 0x0A
                      && !$0.wireData.dropLast().contains(0x0A)
              }) else { return "Malformed raw NDJSON messages" }
        for method in ["thread/start", "turn/start"] {
            let requests = trace.messages.filter {
                $0.direction == .clientToServer && $0.method == method
            }
            guard requests.count == 1,
                  (requests[0].object["params"] as? [String: Any])?["model"] as? String == modelID
            else { return "\(method) used the wrong model or occurred more than once" }
        }
        guard let threadStart = trace.messages.first(where: {
            $0.direction == .clientToServer && $0.method == "thread/start"
        }), let threadParams = threadStart.object["params"] as? [String: Any],
        let specs = threadParams["dynamicTools"] as? [[String: Any]],
        Set(specs.compactMap { $0["name"] as? String })
            == Set(ComputerV2ToolContract.Tool.allCases.map(\.rawValue)),
        specs.count == ComputerV2ToolContract.Tool.allCases.count else {
            return "thread/start did not register exact V2 tools"
        }
        let calls = trace.messages.filter {
            $0.direction == .serverToClient && $0.method == "item/tool/call"
        }
        guard calls.count == expectedTools.count,
              calls.compactMap({
                  ($0.object["params"] as? [String: Any])?["tool"] as? String
              }) == expectedTools else { return "Raw V2 call order changed" }
        for (index, call) in calls.enumerated() {
            guard let params = call.object["params"] as? [String: Any],
                  let arguments = params["arguments"] as? [String: Any],
                  let id = params["callId"] as? String, !id.isEmpty,
                  let threadID = params["threadId"] as? String, !threadID.isEmpty,
                  let turnID = params["turnId"] as? String, !turnID.isEmpty,
                  let requestID = call.identifier,
                  let started = trace.messages.first(where: { message in
                      guard message.direction == .serverToClient,
                            message.method == "item/started",
                            let p = message.object["params"] as? [String: Any],
                            let item = p["item"] as? [String: Any] else { return false }
                      return item["id"] as? String == id
                          && item["type"] as? String == "dynamicToolCall"
                          && item["status"] as? String == "inProgress"
                  }),
                  let response = trace.messages.first(where: {
                      $0.direction == .clientToServer && $0.method == nil
                          && $0.identifier == requestID && $0.sequence > call.sequence
                  }), let result = response.object["result"] as? [String: Any],
                  result["success"] as? Bool == true,
                  let content = result["contentItems"] as? [[String: Any]],
                  let completed = trace.messages.first(where: { message in
                      guard message.direction == .serverToClient,
                            message.method == "item/completed",
                            let p = message.object["params"] as? [String: Any],
                            let item = p["item"] as? [String: Any] else { return false }
                      return item["id"] as? String == id
                          && item["type"] as? String == "dynamicToolCall"
                          && item["status"] as? String == "completed"
                          && item["success"] as? Bool == true
                  }), started.sequence < response.sequence,
                  completed.sequence > response.sequence else {
                return "Call \(index) lacked its matching started/call/result/completed lifecycle"
            }
            if index == 1 {
                guard content.contains(where: {
                    $0["type"] as? String == "inputText"
                        && ($0["text"] as? String)?.contains("capture_id=\(capture.id.uuidString)") == true
                }), content.contains(where: {
                    $0["type"] as? String == "inputImage"
                        && ($0["imageUrl"] as? String)?.hasPrefix("data:image/png;base64,") == true
                }) else { return "Raw capture result omitted ID or PNG image" }
            }
            if index == 2 {
                guard Set(arguments.keys) == ["capture_id", "x", "y"],
                      arguments["capture_id"] as? String == capture.id.uuidString else {
                    return "Raw click arguments did not use the capture ID"
                }
            }
        }
        return nil
    }
}

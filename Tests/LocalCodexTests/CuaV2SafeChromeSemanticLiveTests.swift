import AppKit
import AutomationCore
import Foundation
import Network
import XCTest
@testable import LocalCodex

/// Opt-in end-to-end semantic Chrome gate for the neutral loopback fixture.
/// Only the exact fixture navigation and one AXPress on its named button may
/// be approved. A new test-owned AX session verifies the result independently
/// of the assistant's final answer and its own post-action snapshot.
@MainActor
final class CuaV2SafeChromeSemanticLiveTests: XCTestCase {
    private let chromeBundleID = "com.google.Chrome"
    private let buttonLabel = "Mark semantic complete"

    private struct GateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct RecordedCall {
        let name: String
        let arguments: [String: Any]
        let output: String
    }

    private final class ApprovalAudit {
        var handledIDs = Set<String>()
        var approvedActions = [String]()
        var unexpected = [String]()
    }

    func testQwenPressesSafeChromeSemanticButtonWithV2() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_SAFE_CHROME_SEMANTIC_TEST"] == "1",
            "Set LOCALCODEX_LIVE_SAFE_CHROME_SEMANTIC_TEST=1 to opt in."
        )
        let modelID = try XCTUnwrap(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_MODEL_ID"],
            "Select the installed 4B or 9B model with LOCALCODEX_LIVE_MODEL_ID."
        )
        try XCTSkipUnless(
            [
                "lmstudio-community/Qwen3.5-4B-MLX-4bit",
                "lmstudio-community/Qwen3.5-9B-MLX-4bit",
            ].contains(modelID),
            "This bounded gate excludes the slower 27B and 35B models."
        )
        try XCTSkipUnless(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleID) != nil,
            "Google Chrome is not installed."
        )
        try XCTSkipUnless(
            PermissionInspector().current().accessibility == .granted,
            "The live test host needs Accessibility permission."
        )

        let runID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let expectedResult = "SEMANTIC_OK:\(runID)"
        let completionToken = "LOCALCODEX_SAFE_SEMANTIC_OK_\(runID)"
        let fixture = try SafeLoopbackFixture(runID: runID)
        let pageURL = try await fixture.start()
        defer { fixture.stop() }

        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.codexHomePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCodexSafeSemantic-\(UUID().uuidString)", isDirectory: true)
            .path
        let traceURL = URL(fileURLWithPath: configuration.codexHomePath, isDirectory: true)
            .appendingPathComponent("app-server-wire.jsonl")
        configuration.protocolTracePath = traceURL.path

        let state = AppState(tasks: [], runtime: CodexAppServerRuntime(configuration: configuration))
        let eventTask = Task { await state.startRuntime() }
        defer { eventTask.cancel() }
        try await waitForConnection(state)

        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        XCTAssertTrue(state.setTaskModel(modelID, taskID: taskID))
        let audit = ApprovalAudit()
        let approvalTask = approveOnlyExpectedActions(
            state: state, taskID: taskID, pageURL: pageURL, audit: audit
        )
        defer { approvalTask.cancel() }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let submitted = await state.submit(
            prompt: """
            Use exactly four computer tools in order: computer_v2_open with {"bundle_id":"\(chromeBundleID)","url":"\(pageURL)"}; computer_v2_snapshot with {"query":"\(buttonLabel)"}; computer_v2_ax with the returned snapshot_id and the element_index of the AXButton labeled \(buttonLabel), using ax_action "AXPress"; computer_v2_snapshot with {"query":"\(expectedResult)"}. Check that the fresh final snapshot shows \(expectedResult), then reply with exactly \(completionToken). If any tool fails or the result does not appear, report failure instead. Do not use coordinates, other tools, or another page.
            """,
            toTaskID: taskID
        )
        guard submitted else { throw GateError(message: "The safe Chrome prompt was not submitted.") }

        let completed = try await waitForCompletion(state, taskID: taskID, audit: audit)
        let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        let calls = try recordedCalls(in: completed)
        let expectedNames = [
            "computer_v2_open", "computer_v2_snapshot", "computer_v2_ax", "computer_v2_snapshot",
        ]
        XCTAssertEqual(completed.model, modelID)
        XCTAssertEqual(audit.approvedActions, ["open", "ax"])
        XCTAssertTrue(audit.unexpected.isEmpty, audit.unexpected.joined(separator: "\n"))
        XCTAssertEqual(calls.map(\.name), expectedNames)
        guard calls.count == expectedNames.count else {
            throw GateError(message: "Expected four V2 calls; got \(calls.map(\.name)).")
        }
        let processID = try XCTUnwrap(processIdentifier(in: calls[0].output))
        let snapshotID = try XCTUnwrap(snapshotIdentifier(in: calls[1].output))
        let buttonIndex = try XCTUnwrap(buttonIndex(in: calls[1].output))
        let expectedArguments: [[String: Any]] = [
            ["bundle_id": chromeBundleID, "url": pageURL],
            ["query": buttonLabel],
            ["snapshot_id": snapshotID, "element_index": buttonIndex, "ax_action": "AXPress"],
            ["query": expectedResult],
        ]
        for (index, call) in calls.enumerated() {
            XCTAssertTrue(
                NSDictionary(dictionary: call.arguments).isEqual(to: expectedArguments[index]),
                "V2 call \(index) did not have the exact expected arguments."
            )
        }
        XCTAssertEqual(NSRunningApplication(processIdentifier: processID)?.bundleIdentifier, chromeBundleID)
        XCTAssertTrue(calls[1].output.contains("pid=\(processID) "))
        XCTAssertTrue(calls[1].output.contains("bundle=\"\(chromeBundleID)\""))
        XCTAssertTrue(calls[3].output.contains("pid=\(processID) "))
        XCTAssertTrue(calls[3].output.contains("bundle=\"\(chromeBundleID)\""))
        XCTAssertNotEqual(snapshotIdentifier(in: calls[3].output), snapshotID)
        XCTAssertTrue(
            calls[3].output.contains(expectedResult),
            "The model's fresh snapshot did not expose the semantic completion marker."
        )
        XCTAssertEqual(
            completed.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            completionToken
        )
        try await verifyIndependentChromeResult(
            processID: processID, pageURL: pageURL, expectedResult: expectedResult
        )
        let wire = try await waitForTrace(at: traceURL, expectedToolCount: calls.count)
        try assertWireLifecycle(
            wire, modelID: modelID, expectedNames: expectedNames,
            expectedArguments: expectedArguments, expectedCalls: calls
        )
        print("SAFE_CHROME_SEMANTIC_V2 model=\(modelID) elapsed_ms=\(elapsedMilliseconds) success=1")
    }

    private func approveOnlyExpectedActions(
        state: AppState,
        taskID: AgentTask.ID,
        pageURL: String,
        audit: ApprovalAudit
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                for request in state.pendingApprovals where !audit.handledIDs.contains(request.id) {
                    audit.handledIDs.insert(request.id)
                    let calls = state.tasks.first(where: { $0.id == taskID })
                        .flatMap { try? recordedCalls(in: $0) } ?? []
                    let action: String?
                    if audit.approvedActions.isEmpty,
                       calls.isEmpty,
                       isExactOpenApproval(request, taskID: taskID, pageURL: pageURL) {
                        action = "open"
                    } else if audit.approvedActions == ["open"],
                              isExactAXApproval(
                                  request, taskID: taskID, calls: calls, pageURL: pageURL
                              ) {
                        action = "ax"
                    } else {
                        action = nil
                    }
                    if let action {
                        audit.approvedActions.append(action)
                    } else {
                        audit.unexpected.append("Declined unexpected approval: \(request.summary)")
                    }
                    await state.resolveApproval(request, approved: action != nil)
                    if action == nil { return }
                }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
        }
    }

    private func isExactOpenApproval(
        _ request: ActionApprovalRequest,
        taskID: AgentTask.ID,
        pageURL: String
    ) -> Bool {
        let details = jsonObject(request.details)
        return request.taskID == taskID
            && request.kind == .computerUse
            && request.title == "Allow an application action?"
            && request.summary == "Open \(chromeBundleID) at \(pageURL)"
            && Set(details?.keys.map { $0 } ?? []) == ["bundle_id", "url"]
            && details?["bundle_id"] as? String == chromeBundleID
            && details?["url"] as? String == pageURL
    }

    private func isExactAXApproval(
        _ request: ActionApprovalRequest,
        taskID: AgentTask.ID,
        calls: [RecordedCall],
        pageURL: String
    ) -> Bool {
        guard request.taskID == taskID,
              request.kind == .computerUse,
              request.title == "Allow a desktop action?",
              request.summary == "AXPress on \(buttonLabel)",
              calls.map(\.name) == ["computer_v2_open", "computer_v2_snapshot"],
              let processID = processIdentifier(in: calls[0].output),
              calls[1].output.contains("pid=\(processID) "),
              calls[1].output.contains("bundle=\"\(chromeBundleID)\""),
              let snapshotID = snapshotIdentifier(in: calls[1].output),
              let index = buttonIndex(in: calls[1].output),
              independentlyFocusedFixtureButton(
                  processID: processID,
                  pageURL: pageURL,
                  modelSnapshot: calls[1].output,
                  buttonIndex: index
              )
        else { return false }
        let details = jsonObject(request.details)
        let modelArguments = jsonObject(details?["model_arguments"])
        let target = jsonObject(details?["resolved_target"])
        return Set(details?.keys.map { $0 } ?? []) == ["model_arguments", "resolved_target"]
            && Set(modelArguments?.keys.map { $0 } ?? []) == ["snapshot_id", "element_index", "ax_action"]
            && modelArguments?["snapshot_id"] as? String == snapshotID
            && (modelArguments?["element_index"] as? NSNumber)?.intValue == index
            && modelArguments?["ax_action"] as? String == "AXPress"
            && Set(target?.keys.map { $0 } ?? []) == ["bundle_id", "process_id"]
            && target?["bundle_id"] as? String == chromeBundleID
            && (target?["process_id"] as? NSNumber)?.int32Value == processID
    }

    /// The approval prompt alone is not evidence that Chrome still shows the
    /// inspected tab. Check a new AX tree immediately before approving; the
    /// production runtime performs another focus/identity check before input.
    private func independentlyFocusedFixtureButton(
        processID: Int32,
        pageURL: String,
        modelSnapshot: String,
        buttonIndex: Int
    ) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: processID),
              running.bundleIdentifier == chromeBundleID,
              !running.isTerminated,
              let limits = try? AccessibilityTreeLimits(
                  maxDepth: 16, maxElements: 1_000, maxChildrenPerElement: 80,
                  maxActionsPerElement: 12, maxTextLength: 1_024
              ) else { return false }
        let session = AccessibilitySession(
            processIdentifier: processID,
            bundleIdentifier: chromeBundleID,
            applicationName: running.localizedName
        )
        guard let snapshot = try? session.snapshot(limits: limits),
              (try? session.focusState(in: snapshot)) == .focused,
              let rootIndex = snapshot.rootIndex,
              let root = snapshot.element(at: rootIndex),
              root.role == "AXWindow",
              let rootTitle = root.title,
              modelSnapshot.contains("#\(rootIndex) role=\"AXWindow/"),
              modelSnapshot.contains("label=\"\(rootTitle)\""),
              modelSnapshot.contains("screen_frame=\(formattedFrame(root.frame))"),
              snapshot.elements.filter({
                  chromeAddress($0, matches: pageURL)
              }).count == 1,
              let button = snapshot.element(at: buttonIndex),
              button.role == "AXButton",
              [button.title, button.elementDescription, button.value]
                  .contains(where: { $0 == buttonLabel }),
              button.supportedActions.contains("AXPress"),
              hasAncestor(role: "AXWebArea", of: button, in: snapshot)
        else { return false }
        return true
    }

    private func formattedFrame(_ frame: WindowFrame?) -> String {
        guard let frame else { return "-" }
        let values = [frame.x, frame.y, frame.width, frame.height].map {
            String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), $0)
        }
        return "[\(values.joined(separator: ","))]"
    }

    private func verifyIndependentChromeResult(
        processID: Int32,
        pageURL: String,
        expectedResult: String
    ) async throws {
        let limits = try AccessibilityTreeLimits(
            maxDepth: 16, maxElements: 1_000, maxChildrenPerElement: 200,
            maxActionsPerElement: 12, maxTextLength: 1_024
        )
        for attempt in 0..<20 {
            guard let running = NSRunningApplication(processIdentifier: processID),
                  running.bundleIdentifier == chromeBundleID,
                  !running.isTerminated else {
                throw GateError(message: "The bound Chrome process is no longer running.")
            }
            let session = AccessibilitySession(
                processIdentifier: processID,
                bundleIdentifier: chromeBundleID,
                applicationName: running.localizedName
            )
            let snapshot = try session.snapshot(limits: limits)
            guard try session.focusState(in: snapshot) == .focused else {
                throw GateError(message: "The bound Chrome window is no longer focused.")
            }
            let hasExactAddress = snapshot.elements.contains {
                chromeAddress($0, matches: pageURL)
            }
            let hasExactResult = outputValue(
                id: "semantic-result", equals: expectedResult, in: snapshot
            )
            let otherOutputsStayedReady = [
                "visual-result", "form-result", "delayed-result", "tab-result", "scroll-result",
            ].allSatisfy { outputValue(id: $0, equals: "READY", in: snapshot) }
            if hasExactAddress && hasExactResult && otherOutputsStayedReady { return }
            if attempt < 19 { try await Task.sleep(for: .milliseconds(250)) }
        }
        throw GateError(
            message: "Independent Chrome AX did not show the unique loopback URL, "
                + "the exact semantic output \(expectedResult), and all unrelated outputs READY."
        )
    }

    private func outputValue(
        id: String,
        equals expected: String,
        in snapshot: AccessibilityTreeSnapshot
    ) -> Bool {
        let matchingOutputs = snapshot.elements.filter { element in
            (element.domIdentifier == id || element.identifier == id)
                && hasAncestor(role: "AXWebArea", of: element, in: snapshot)
        }
        guard matchingOutputs.count == 1, let output = matchingOutputs.first else {
            return false
        }
        return snapshot.elements.contains { element in
            (element.index == output.index || isDescendant(element, of: output, in: snapshot))
                && [element.title, element.elementDescription, element.value]
                    .contains(where: { $0 == expected })
        }
    }

    private func isDescendant(
        _ element: AccessibilityTreeElement,
        of ancestor: AccessibilityTreeElement,
        in snapshot: AccessibilityTreeSnapshot
    ) -> Bool {
        var index = element.parentIndex
        while let currentIndex = index,
              let current = snapshot.element(at: currentIndex) {
            if current.index == ancestor.index { return true }
            index = current.parentIndex
        }
        return false
    }

    private func chromeAddress(
        _ element: AccessibilityTreeElement,
        matches pageURL: String
    ) -> Bool {
        guard element.role == "AXTextField",
              [element.title, element.elementDescription]
                  .contains(where: { $0 == "Address and search bar" }),
              let value = element.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return false }
        return value == pageURL || "http://\(value)" == pageURL
    }

    private func hasAncestor(
        role: String,
        of element: AccessibilityTreeElement,
        in snapshot: AccessibilityTreeSnapshot
    ) -> Bool {
        var index = element.parentIndex
        while let currentIndex = index,
              let ancestor = snapshot.element(at: currentIndex) {
            if ancestor.role == role { return true }
            index = ancestor.parentIndex
        }
        return false
    }

    private func waitForConnection(_ state: AppState) async throws {
        for _ in 0..<80 {
            switch state.connectionState {
            case .connected: return
            case .failed(let message): throw GateError(message: "Runtime connection failed: \(message)")
            case .connecting, .disconnected: break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GateError(message: "Timed out waiting for the App Server connection.")
    }

    private func waitForCompletion(
        _ state: AppState,
        taskID: AgentTask.ID,
        audit: ApprovalAudit
    ) async throws -> AgentTask {
        for _ in 0..<3_600 {
            if let unexpected = audit.unexpected.first { throw GateError(message: unexpected) }
            if case .failed(let message) = state.connectionState {
                throw GateError(message: "App Server failed: \(message)")
            }
            guard let task = state.tasks.first(where: { $0.id == taskID }) else {
                throw GateError(message: "The safe Chrome task disappeared.")
            }
            if task.status == .completed { return task }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GateError(message: "Timed out waiting for the safe Chrome turn.")
    }

    private func recordedCalls(in task: AgentTask) throws -> [RecordedCall] {
        try task.entries.compactMap { entry in
            guard let event = entry.toolEvent else { return nil }
            guard event.name.hasPrefix("computer_v2_"),
                  event.status == .succeeded,
                  let item = jsonObject(event.input),
                  item["tool"] as? String == event.name,
                  let arguments = jsonObject(item["arguments"]),
                  let content = item["contentItems"] as? [[String: Any]] else {
                throw GateError(message: "Malformed or unsuccessful computer call: \(event.name)")
            }
            let output = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return RecordedCall(name: event.name, arguments: arguments, output: output)
        }
    }

    private func snapshotIdentifier(in text: String) -> String? {
        capture(#"AXSNAPSHOT id=([0-9A-Fa-f-]{36})"#, from: text).flatMap {
            UUID(uuidString: $0) == nil ? nil : $0
        }
    }

    private func processIdentifier(in text: String) -> Int32? {
        capture(#""processIdentifier"\s*:\s*(\d+)"#, from: text).flatMap { Int32($0) }
    }

    private func buttonIndex(in text: String) -> Int? {
        let candidates = text.split(separator: "\n").compactMap { line -> Int? in
            guard line.contains("role=\"AXButton\" label=\"\(buttonLabel)\""),
                  line.contains("\"AXPress\""),
                  line.first == "#",
                  let space = line.firstIndex(of: " ") else { return nil }
            return Int(line[line.index(after: line.startIndex)..<space])
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func capture(_ pattern: String, from text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: text, range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func waitForTrace(
        at url: URL,
        expectedToolCount: Int
    ) async throws -> AppServerWireTrace {
        for _ in 0..<80 {
            if let trace = try? AppServerWireTrace.load(url),
               trace.messages.filter({ message in
                   guard message.direction == .serverToClient,
                         message.method == "item/completed",
                         let item = (message.object["params"] as? [String: Any])?["item"]
                            as? [String: Any] else { return false }
                   return item["type"] as? String == "dynamicToolCall"
               }).count >= expectedToolCount { return trace }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GateError(message: "The App Server wire trace did not complete.")
    }

    private func assertWireLifecycle(
        _ trace: AppServerWireTrace,
        modelID: String,
        expectedNames: [String],
        expectedArguments: [[String: Any]],
        expectedCalls: [RecordedCall]
    ) throws {
        XCTAssertTrue(trace.parseFailures.isEmpty, trace.parseFailures.joined(separator: "\n"))
        XCTAssertEqual(trace.messages.map(\.sequence), Array(1...trace.messages.count))
        XCTAssertTrue(trace.messages.allSatisfy { $0.wireData.last == 0x0A })
        for method in ["thread/start", "turn/start"] {
            let requests = trace.messages.filter {
                $0.direction == .clientToServer && $0.method == method
            }
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(
                (requests.first?.object["params"] as? [String: Any])?["model"] as? String,
                modelID
            )
        }
        let start = try XCTUnwrap(trace.messages.first {
            $0.direction == .clientToServer && $0.method == "thread/start"
        })
        let registered = try XCTUnwrap(
            (start.object["params"] as? [String: Any])?["dynamicTools"] as? [[String: Any]]
        )
        XCTAssertEqual(
            Set(registered.compactMap { $0["name"] as? String }),
            Set(ComputerV2ToolContract.Tool.allCases.map(\.rawValue))
        )
        let calls = trace.messages.filter {
            $0.direction == .serverToClient && $0.method == "item/tool/call"
        }
        XCTAssertEqual(calls.count, expectedNames.count)
        guard calls.count == expectedNames.count else { return }
        XCTAssertEqual(
            calls.compactMap { ($0.object["params"] as? [String: Any])?["tool"] as? String },
            expectedNames
        )
        for (index, call) in calls.enumerated() {
            let params = try XCTUnwrap(call.object["params"] as? [String: Any])
            let callID = try XCTUnwrap(params["callId"] as? String)
            let requestID = try XCTUnwrap(call.identifier)
            let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
            XCTAssertTrue(NSDictionary(dictionary: arguments).isEqual(to: expectedArguments[index]))
            let started = try XCTUnwrap(trace.messages.first { message in
                guard message.direction == .serverToClient,
                      message.method == "item/started",
                      let item = (message.object["params"] as? [String: Any])?["item"]
                        as? [String: Any] else { return false }
                return item["id"] as? String == callID
                    && item["type"] as? String == "dynamicToolCall"
                    && item["status"] as? String == "inProgress"
            })
            let response = try XCTUnwrap(trace.messages.first {
                $0.direction == .clientToServer && $0.method == nil
                    && $0.identifier == requestID && $0.sequence > call.sequence
            })
            let result = try XCTUnwrap(response.object["result"] as? [String: Any])
            XCTAssertEqual(result["success"] as? Bool, true)
            let content = try XCTUnwrap(result["contentItems"] as? [[String: Any]])
            XCTAssertEqual(
                content.compactMap { $0["text"] as? String }.joined(separator: "\n"),
                expectedCalls[index].output
            )
            let completed = try XCTUnwrap(trace.messages.first { message in
                guard message.direction == .serverToClient,
                      message.method == "item/completed",
                      let item = (message.object["params"] as? [String: Any])?["item"]
                        as? [String: Any] else { return false }
                return item["id"] as? String == callID
                    && item["type"] as? String == "dynamicToolCall"
                    && item["status"] as? String == "completed"
                    && item["success"] as? Bool == true
            })
            XCTAssertLessThan(started.sequence, response.sequence)
            XCTAssertLessThan(call.sequence, response.sequence)
            XCTAssertLessThan(response.sequence, completed.sequence)
        }
    }

    private func jsonObject(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let string = value as? String,
              let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// A test-only HTTP listener restricted to the exact safe fixture URL. It
/// never serves the repository, user files, or a public network interface.
private final class SafeLoopbackFixture: @unchecked Sendable {
    private let listener: NWListener
    private let html: Data
    private let expectedPath: String
    private let queue = DispatchQueue(label: "LocalCodex.SafeLoopbackFixture")
    private let lock = NSLock()
    private var readyPort: UInt16?
    private var startupError: String?

    init(runID: String) throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CuaV2SafeBenchmark.html")
        html = try Data(contentsOf: fixtureURL)
        expectedPath = "/CuaV2SafeBenchmark.html?run=\(runID)&tab=A"
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: .any
        )
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            switch state {
            case .ready: self.readyPort = self.listener.port?.rawValue
            case .failed(let error): self.startupError = error.localizedDescription
            default: break
            }
        }
    }

    func start() async throws -> String {
        listener.start(queue: queue)
        for _ in 0..<100 {
            let (port, error) = lock.withLock { (readyPort, startupError) }
            if let error { throw FixtureError(message: "Loopback listener failed: \(error)") }
            if let port { return "http://127.0.0.1:\(port)\(expectedPath)" }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FixtureError(message: "Timed out starting the loopback fixture.")
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            var request = accumulated
            if let data { request.append(data) }
            guard error == nil, request.count <= 8_192 else {
                connection.cancel()
                return
            }
            let delimiter = Data("\r\n".utf8)
            guard let lineEnd = request.range(of: delimiter) else {
                if isComplete { connection.cancel() }
                else { self.receiveRequest(on: connection, accumulated: request) }
                return
            }
            let requestLine = String(data: request[..<lineEnd.lowerBound], encoding: .utf8) ?? ""
            let allowed = requestLine == "GET \(self.expectedPath) HTTP/1.1"
                || requestLine == "GET \(self.expectedPath) HTTP/1.0"
            let body = allowed ? self.html : Data("Not Found".utf8)
            let header = "HTTP/1.1 \(allowed ? "200 OK" : "404 Not Found")\r\n"
                + "Content-Type: \(allowed ? "text/html; charset=utf-8" : "text/plain; charset=utf-8")\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var response = Data(header.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private struct FixtureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

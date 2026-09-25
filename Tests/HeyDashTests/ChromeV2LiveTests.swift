import AppKit
import AutomationCore
import Foundation
import XCTest
@testable import HeyDash

/// An opt-in Chrome gate for the versioned computer contract. The only
/// approved mutation is opening a known public URL; the model then reads the
/// bound Chrome AX tree. This intentionally does not use the blocked file URL
/// fixture or claim to test visual clicking.
@MainActor
final class ChromeV2LiveTests: XCTestCase {
    private let bundleID = "com.google.Chrome"
    private let snapshotQuery = "Example Domain"
    private let maxSnapshotCalls = 3

    private final class ApprovalAudit {
        var approvedOpen = false
        var unexpected = [String]()
        var handledIDs = Set<String>()
    }

    private struct GateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class ShutdownAudit {
        var report: RuntimeShutdownReport?
    }

    /// Model-free primitive in the exact same signed HeyDash test host as the
    /// model gate. Never inspects the original tab: only the newly opened public
    /// nonce fixture is read, and only sanitized phase/PID proof is printed.
    func testExistingChromeNativeOpenPrimitive() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HEYDASH_LIVE_EXISTING_CHROME_PRIMITIVE"] == "1",
            "Set HEYDASH_LIVE_EXISTING_CHROME_PRIMITIVE=1 to opt in."
        )
        guard PermissionInspector().current().accessibility == .granted else {
            throw GateError(message: "The live test host does not have Accessibility access.")
        }
        let chromePIDsBefore = runningChromePIDs()
        guard let rawPID = ProcessInfo.processInfo.environment["HEYDASH_EXPECTED_CHROME_PID"],
              let expectedPID = Int32(rawPID), expectedPID > 0,
              chromePIDsBefore.contains(expectedPID) else {
            throw GateError(message: "HEYDASH_EXPECTED_CHROME_PID must identify an already-running Google Chrome process.")
        }
        defer {
            XCTAssertEqual(runningChromePIDs(), chromePIDsBefore,
                           "The native primitive must neither replace nor launch another Chrome process.")
        }
        let controller = ExistingChromeController(diagnostics: { diagnostic in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(diagnostic),
               let payload = String(data: data, encoding: .utf8) {
                print("HEYDASH_EXISTING_CHROME_DIAGNOSTIC \(payload)")
            }
        })
        let startedAt = DispatchTime.now().uptimeNanoseconds
        print("HEYDASH_EXISTING_CHROME_PRIMITIVE phase=activate expected_pid=\(expectedPID)")
        let activated = try await controller.open(url: nil)
        guard activated.processIdentifier == expectedPID, activated.bundleIdentifier == bundleID else {
            throw GateError(message: "Native activation did not reuse the exact expected Chrome PID.")
        }
        XCTAssertEqual(runningChromePIDs(), chromePIDsBefore)
        print("HEYDASH_EXISTING_CHROME_PRIMITIVE phase=activated actual_pid=\(activated.processIdentifier)")

        let pageURL = "https://example.com/?heydash_native_read_id=\(UUID().uuidString)"
        let url = try XCTUnwrap(URL(string: pageURL))
        print("HEYDASH_EXISTING_CHROME_PRIMITIVE phase=open_public_nonce expected_pid=\(expectedPID)")
        let opened = try await controller.open(url: url)
        guard opened.processIdentifier == expectedPID, opened.bundleIdentifier == bundleID else {
            throw GateError(message: "Native URL open did not reuse the exact expected Chrome PID.")
        }
        XCTAssertEqual(runningChromePIDs(), chromePIDsBefore)
        try await verifyFocusedChromePage(processID: expectedPID, pageURL: pageURL)
        let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        print("HEYDASH_EXISTING_CHROME_PRIMITIVE phase=verified actual_pid=\(expectedPID) heading_verified=true nonce_address_verified=true chrome_pid_set_unchanged=\(runningChromePIDs() == chromePIDsBefore) elapsed_ms=\(elapsedMilliseconds)")
    }

    func testBoundChromeReadOnlyV2WithSelectedModel() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_CHROME_V2_READ_TEST"] == "1",
            "Set LOCALCODEX_LIVE_CHROME_V2_READ_TEST=1 to opt in to the Chrome V2 gate."
        )
        let modelID = try XCTUnwrap(
            ProcessInfo.processInfo.environment["LOCALCODEX_LIVE_MODEL_ID"],
            "Select one installed model explicitly with LOCALCODEX_LIVE_MODEL_ID."
        )
        guard LocalModelCatalog.option(for: modelID) != nil else {
            throw GateError(message: "The selected model is not in LocalModelCatalog.")
        }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            throw GateError(message: "Google Chrome is not installed.")
        }
        guard PermissionInspector().current().accessibility == .granted else {
            throw GateError(message: "The live test host does not have Accessibility access.")
        }
        let chromePIDsBeforeTurn = runningChromePIDs()
        let expectedChromePID: Int32?
        if let rawPID = ProcessInfo.processInfo.environment["HEYDASH_EXPECTED_CHROME_PID"] {
            guard let processID = Int32(rawPID), processID > 0,
                  chromePIDsBeforeTurn.contains(processID) else {
                throw GateError(message: "HEYDASH_EXPECTED_CHROME_PID must identify an already-running Google Chrome process.")
            }
            expectedChromePID = processID
        } else {
            expectedChromePID = nil
        }
        let pageURL = "https://example.com/?localcodex_read_id=\(UUID().uuidString)"

        var configuration = CodexAppServerRuntime.Configuration.localQwen
        configuration.codexHomePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCodexChromeV2-\(UUID().uuidString)", isDirectory: true)
            .path
        let traceURL = URL(fileURLWithPath: configuration.codexHomePath, isDirectory: true)
            .appendingPathComponent("app-server-wire.jsonl")
        configuration.protocolTracePath = traceURL.path

        let state = AppState(tasks: [], runtime: CodexAppServerRuntime(configuration: configuration), preferences: isolatedTestPreferences())
        let eventTask = Task { await state.startRuntime() }
        addTeardownBlock { @MainActor in
            // Runs on success, thrown validation failures, and model timeout.
            // Shut down only this fixture's runtime; the user's Chrome must survive.
            defer { eventTask.cancel() }
            do {
                let report = try await self.shutdownRuntimeBounded(state)
                XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
            } catch {
                XCTFail("Chrome V2 runtime cleanup failed: \(error.localizedDescription)")
            }
            if let expectedChromePID {
                XCTAssertTrue(self.runningChromePIDs().contains(expectedChromePID),
                              "Runtime cleanup terminated the user's preexisting Chrome.")
                XCTAssertEqual(self.runningChromePIDs(), chromePIDsBeforeTurn,
                               "Runtime cleanup changed the set of existing Chrome processes.")
            }
        }
        try await waitForConnection(state)

        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        XCTAssertTrue(state.setTaskModel(modelID, taskID: taskID))

        let audit = ApprovalAudit()
        let approvalTask = approveOnlyExpectedOpen(
            state: state, taskID: taskID, pageURL: pageURL, audit: audit
        )
        defer { approvalTask.cancel() }

        let token = "LOCALCODEX_CHROME_V2_READ_OK_" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
        let submitted = await state.submit(
            prompt: """
            Call computer_v2_open exactly once with {"bundle_id":"\(bundleID)","url":"\(pageURL)"}. Then call computer_v2_snapshot with exactly {"query":"\(snapshotQuery)"}. If the snapshot does not yet show an AXHeading for \(snapshotQuery), retry the same read-only snapshot until it does, using at most \(maxSnapshotCalls) snapshot calls total. Stop retrying when the heading appears. Confirm the final AXSNAPSHOT header identifies the bound Chrome bundle and process and its page heading says \(snapshotQuery). Only after that observation, reply with exactly \(token). If the heading never appears, report failure instead of the token. Use no other tools; do not click, type, or navigate elsewhere.
            """,
            toTaskID: taskID
        )
        guard submitted else { throw GateError(message: "The Chrome V2 prompt was not submitted.") }

        let completed = try await waitForCompletion(state, taskID: taskID, audit: audit)
        XCTAssertEqual(completed.model, modelID)
        XCTAssertTrue(audit.approvedOpen)
        XCTAssertTrue(audit.unexpected.isEmpty, audit.unexpected.joined(separator: "\n"))
        let toolNames = completed.entries.compactMap(\.toolEvent).map(\.name)
        guard (2...(maxSnapshotCalls + 1)).contains(toolNames.count),
              toolNames == ["computer_v2_open"] + Array(
                repeating: "computer_v2_snapshot", count: toolNames.count - 1
              ) else {
            throw GateError(message: "Expected one Chrome open and one to \(maxSnapshotCalls) read-only snapshots; got \(toolNames).")
        }
        let calls = try completed.entries.compactMap {
            entry -> (name: String, arguments: [String: Any], output: String)? in
            guard let tool = entry.toolEvent else { return nil }
            guard let item = jsonObject(tool.input),
                  item["tool"] as? String == tool.name,
                  let arguments = jsonObject(item["arguments"]),
                  let content = item["contentItems"] as? [[String: Any]],
                  tool.status == .succeeded else {
                throw GateError(message: "Malformed or unsuccessful V2 transcript call: \(tool.name)")
            }
            let output = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return (tool.name, arguments, output)
        }
        XCTAssertEqual(calls.map(\.name), toolNames)
        XCTAssertEqual(Set(calls[0].arguments.keys), ["bundle_id", "url"])
        XCTAssertEqual(calls[0].arguments["bundle_id"] as? String, bundleID)
        XCTAssertEqual(calls[0].arguments["url"] as? String, pageURL)
        let processID = try XCTUnwrap(processIdentifier(in: calls[0].output))
        XCTAssertEqual(NSRunningApplication(processIdentifier: processID)?.bundleIdentifier, bundleID)
        XCTAssertTrue(calls[0].output.contains("BROWSER_SESSION profile=existing"))
        XCTAssertFalse(calls[0].output.contains("BROWSER_TAB"))
        if let expectedChromePID {
            XCTAssertEqual(processID, expectedChromePID,
                           "The default open did not reuse the exact preexisting Chrome process.")
            XCTAssertEqual(runningChromePIDs(), chromePIDsBeforeTurn,
                           "The default open unexpectedly created or replaced a Chrome process.")
        }
        for snapshot in calls.dropFirst() {
            XCTAssertEqual(Set(snapshot.arguments.keys), ["query"])
            XCTAssertEqual(snapshot.arguments["query"] as? String, snapshotQuery)
            XCTAssertTrue(snapshot.output.contains("AXSNAPSHOT id="))
            XCTAssertTrue(snapshot.output.contains("pid=\(processID) "))
            XCTAssertTrue(snapshot.output.contains("bundle=\"\(bundleID)\""))
        }
        XCTAssertTrue(
            modelSnapshotHasPageHeading(try XCTUnwrap(calls.last).output),
            "The model's final snapshot did not expose the Example Domain page heading."
        )
        try await verifyFocusedChromePage(processID: processID, pageURL: pageURL)
        XCTAssertEqual(
            completed.entries.last(where: { $0.kind == .assistant })?.body
                .trimmingCharacters(in: .whitespacesAndNewlines),
            token
        )

        let trace = try await waitForTrace(at: traceURL, expectedToolCount: calls.count)
        try assertWireLifecycle(
            trace, modelID: modelID, processID: processID, pageURL: pageURL,
            expectedCalls: calls
        )
        let shutdownReport = try await shutdownRuntimeBounded(state)
        XCTAssertTrue(shutdownReport.succeeded, shutdownReport.issues.joined(separator: "; "))
        if let expectedChromePID {
            XCTAssertTrue(runningChromePIDs().contains(expectedChromePID),
                          "The existing Chrome session must remain after runtime shutdown.")
            XCTAssertEqual(runningChromePIDs(), chromePIDsBeforeTurn)
        }
    }

    private func runningChromePIDs() -> Set<Int32> {
        Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
            .map(\.processIdentifier))
    }

    private func shutdownRuntimeBounded(_ state: AppState) async throws -> RuntimeShutdownReport {
        let audit = ShutdownAudit()
        let shutdown = Task { @MainActor in
            audit.report = await state.shutdownRuntime()
        }
        defer { shutdown.cancel() }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let report = audit.report { return report }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw GateError(message: "Runtime shutdown did not finish within 15 seconds.")
    }

    private func approveOnlyExpectedOpen(
        state: AppState,
        taskID: AgentTask.ID,
        pageURL: String,
        audit: ApprovalAudit
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                for request in state.pendingApprovals
                where !audit.handledIDs.contains(request.id) {
                    audit.handledIDs.insert(request.id)
                    let details = jsonObject(request.details)
                    let noPriorTools = state.tasks.first(where: { $0.id == taskID })?
                        .entries.contains(where: { $0.toolEvent?.name.hasPrefix("computer_v2_") == true }) == false
                    let approved = !audit.approvedOpen && noPriorTools
                        && request.taskID == taskID
                        && request.kind == .computerUse
                        && request.title == "Allow an application action?"
                        && request.summary == "Open \(bundleID) at \(pageURL)"
                        && details?["bundle_id"] as? String == bundleID
                        && details?["url"] as? String == pageURL
                        && Set(details?.keys.map { $0 } ?? []) == ["bundle_id", "url"]
                    if approved {
                        audit.approvedOpen = true
                    } else {
                        audit.unexpected.append("Declined unexpected approval: \(request.summary)")
                    }
                    await state.resolveApproval(request, approved: approved)
                    if !approved { return }
                }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
        }
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
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let unexpected = audit.unexpected.first { throw GateError(message: unexpected) }
            if case .failed(let message) = state.connectionState {
                throw GateError(message: "App Server failed: \(message)")
            }
            guard let task = state.tasks.first(where: { $0.id == taskID }) else {
                throw GateError(message: "The Chrome V2 task disappeared.")
            }
            if task.status == .completed { return task }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GateError(message: "Timed out waiting for the Chrome V2 turn.")
    }

    private func verifyFocusedChromePage(processID: Int32, pageURL: String) async throws {
        let limits = try AccessibilityTreeLimits(
            maxDepth: 16, maxElements: 1_000, maxChildrenPerElement: 200,
            maxActionsPerElement: 12, maxTextLength: 1_024
        )
        for attempt in 0..<20 {
            guard let running = NSRunningApplication(processIdentifier: processID),
                  running.bundleIdentifier == bundleID, !running.isTerminated else {
                throw GateError(message: "The bound Chrome process is no longer running.")
            }
            let session = AccessibilitySession(
                processIdentifier: processID,
                bundleIdentifier: bundleID,
                applicationName: running.localizedName
            )
            let snapshot = try session.snapshot(limits: limits)
            guard try session.focusState(in: snapshot) == .focused else {
                throw GateError(message: "The bound Chrome window is no longer focused.")
            }

            let addressFields = snapshot.elements.filter {
                $0.role == "AXTextField" && chromeAddress($0.value, matches: pageURL)
            }
            let pageHeading = snapshot.elements.contains { element in
                let isHeading = element.role == "AXHeading"
                    || (element.role == "AXStaticText"
                        && hasAncestor(role: "AXHeading", of: element, in: snapshot))
                return isHeading
                    && [element.title, element.elementDescription, element.value]
                        .contains(where: { $0 == snapshotQuery })
                    && hasAncestor(role: "AXWebArea", of: element, in: snapshot)
            }
            if addressFields.count == 1 && pageHeading { return }
            if attempt < 19 { try await Task.sleep(for: .milliseconds(250)) }
        }
        throw GateError(
            message: "The focused Chrome AX window did not show the unique gate URL "
                + "in one address field and the Example Domain page heading."
        )
    }

    private func chromeAddress(_ value: String?, matches pageURL: String) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return false }
        // Chrome may omit the HTTPS scheme from the displayed address value.
        return value == pageURL || "https://\(value)" == pageURL
    }

    private func modelSnapshotHasPageHeading(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            line.contains("role=\"AXHeading\"")
                && line.contains("\"\(snapshotQuery)\"")
        }
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
               }).count >= expectedToolCount {
                return trace
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GateError(message: "The App Server wire trace did not complete.")
    }

    private func assertWireLifecycle(
        _ trace: AppServerWireTrace,
        modelID: String,
        processID: Int32,
        pageURL: String,
        expectedCalls: [(name: String, arguments: [String: Any], output: String)]
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
        let startParams = try XCTUnwrap(start.object["params"] as? [String: Any])
        let registered = try XCTUnwrap(startParams["dynamicTools"] as? [[String: Any]])
        XCTAssertEqual(
            Set(registered.compactMap { $0["name"] as? String }),
            Set(ComputerV2ToolContract.Tool.allCases.map(\.rawValue))
        )
        let calls = trace.messages.filter {
            $0.direction == .serverToClient && $0.method == "item/tool/call"
        }
        XCTAssertEqual(calls.count, expectedCalls.count)
        guard calls.count == expectedCalls.count else { return }
        XCTAssertEqual(
            calls.compactMap { ($0.object["params"] as? [String: Any])?["tool"] as? String },
            expectedCalls.map(\.name)
        )
        for (index, call) in calls.enumerated() {
            let params = try XCTUnwrap(call.object["params"] as? [String: Any])
            let callID = try XCTUnwrap(params["callId"] as? String)
            let requestID = try XCTUnwrap(call.identifier)
            let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
            if index == 0 {
                XCTAssertEqual(Set(arguments.keys), ["bundle_id", "url"])
                XCTAssertEqual(arguments["bundle_id"] as? String, bundleID)
                XCTAssertEqual(arguments["url"] as? String, pageURL)
            } else {
                XCTAssertEqual(Set(arguments.keys), ["query"])
                XCTAssertEqual(arguments["query"] as? String, snapshotQuery)
            }
            let started = try XCTUnwrap(trace.messages.first { message in
                guard message.direction == .serverToClient,
                      message.method == "item/started",
                      let item = (message.object["params"] as? [String: Any])?["item"] as? [String: Any]
                else { return false }
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
            let output = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            XCTAssertEqual(output, expectedCalls[index].output)
            if index == 0 {
                XCTAssertEqual(processIdentifier(in: output), processID)
                XCTAssertTrue(output.contains(bundleID))
            } else {
                XCTAssertTrue(output.contains("AXSNAPSHOT id="))
                XCTAssertTrue(output.contains("pid=\(processID) "))
                XCTAssertTrue(output.contains("bundle=\"\(bundleID)\""))
                if index == calls.count - 1 {
                    XCTAssertTrue(modelSnapshotHasPageHeading(output))
                }
            }
            let completed = try XCTUnwrap(trace.messages.first { message in
                guard message.direction == .serverToClient,
                      message.method == "item/completed",
                      let item = (message.object["params"] as? [String: Any])?["item"] as? [String: Any]
                else { return false }
                return item["id"] as? String == callID
                    && item["type"] as? String == "dynamicToolCall"
                    && item["status"] as? String == "completed"
                    && item["success"] as? Bool == true
            })
            // App Server can emit the call request before item/started. Both
            // must precede our reply; completion must follow it.
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

    private func processIdentifier(in text: String) -> Int32? {
        guard let expression = try? NSRegularExpression(pattern: #""processIdentifier"\s*:\s*(\d+)"#),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int32(text[range])
    }
}

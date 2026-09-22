import AppKit
import AutomationCore
@preconcurrency import Foundation

/// A small native client for the open-source Codex App Server protocol.
///
/// App Server owns the agent loop, thread state, MCP startup, sandboxing, and
/// tool execution. This adapter keeps JSON-RPC out of the SwiftUI layer and
/// deliberately declines approval requests until the GUI presents them.
final class CodexAppServerRuntime: AgentRuntimeClient, @unchecked Sendable {
    struct Configuration: Sendable {
        var executablePath: String
        var modelProvider: String
        var model: String
        var workspacePath: String
        var codexHomePath: String
        var baseInstructions: String
        var reasoningEffort: String

        static var localQwen: Configuration {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
            let codexHome = applicationSupport
                .appendingPathComponent("LocalCodex", isDirectory: true)
                .appendingPathComponent("CodexHome", isDirectory: true)

            return Configuration(
                executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex",
                modelProvider: "lmstudio",
                model: "mlx-community/Qwen3.8-27B-4bit",
                workspacePath: documents,
                codexHomePath: codexHome.path,
                baseInstructions: """
                You are LocalCodex, a concise local desktop agent. Follow the user's request precisely. Use the provided desktop tools when helpful, respect approval gates, and never claim an action succeeded unless a tool confirms it.
                """,
                reasoningEffort: "medium"
            )
        }
    }

    nonisolated let providerName = "Codex App Server (LM Studio selected)"

    private let core: Core
    private let eventStream: AsyncStream<AgentRuntimeEvent>

    init(configuration: Configuration) {
        var continuation: AsyncStream<AgentRuntimeEvent>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        core = Core(configuration: configuration, events: continuation!)
    }

    func loadTasks() async throws -> [AgentTask] {
        try await core.start()
        return try await core.loadTasks()
    }

    func events() -> AsyncStream<AgentRuntimeEvent> {
        eventStream
    }

    func submit(prompt: String, toTaskID taskID: AgentTask.ID) async throws {
        try await core.submit(prompt: prompt, taskID: taskID)
    }

    func resolveApproval(requestID: String, approved: Bool) async throws {
        try await core.resolveApproval(requestID: requestID, approved: approved)
    }
}

private extension CodexAppServerRuntime {
    actor Core {
        private enum ServerRequestID: Hashable, Sendable {
            case integer(Int64)
            case string(String)

            var jsonValue: Any {
                switch self {
                case .integer(let value): value
                case .string(let value): value
                }
            }
        }

        private struct PendingServerApproval {
            let serverRequestID: ServerRequestID
            let method: String
            let request: ActionApprovalRequest
        }

        private struct ActiveAccessibilitySession {
            let session: AccessibilitySession
            let snapshot: AccessibilityTreeSnapshot
        }

        enum RuntimeError: LocalizedError {
            case executableMissing(String)
            case serverStopped
            case malformedResponse(String)
            case serverError(String)

            var errorDescription: String? {
                switch self {
                case .executableMissing(let path):
                    "Codex executable was not found at \(path)."
                case .serverStopped:
                    "Codex App Server stopped unexpectedly."
                case .malformedResponse(let detail):
                    "Codex App Server returned an invalid response: \(detail)"
                case .serverError(let detail):
                    detail
                }
            }
        }

        private let configuration: Configuration
        private let events: AsyncStream<AgentRuntimeEvent>.Continuation

        private var process: Process?
        private var input: FileHandle?
        private var outputHandle: FileHandle?
        private var errorHandle: FileHandle?
        private var outputBuffer = Data()
        private var nextRequestID = 1
        private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
        private var threadForTask: [AgentTask.ID: String] = [:]
        private var taskForThread: [String: AgentTask.ID] = [:]
        private var resumedThreads: Set<String> = []
        private var lastErrorMessageForTask: [AgentTask.ID: String] = [:]
        private var pendingServerApprovals: [String: PendingServerApproval] = [:]
        private var pendingComputerUseApprovals: [String: CheckedContinuation<Bool, Never>] = [:]
        private var accessibilitySessions: [Int32: ActiveAccessibilitySession] = [:]
        private var isReady = false

        init(
            configuration: Configuration,
            events: AsyncStream<AgentRuntimeEvent>.Continuation
        ) {
            self.configuration = configuration
            self.events = events
        }

        func start() async throws {
            guard !isReady else { return }
            guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else {
                throw RuntimeError.executableMissing(configuration.executablePath)
            }

            events.yield(.connectionChanged(.connecting))

            let process = Process()
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = URL(fileURLWithPath: configuration.executablePath)
            process.arguments = ["app-server", "--listen", "stdio://"]
            try FileManager.default.createDirectory(
                atPath: configuration.codexHomePath,
                withIntermediateDirectories: true
            )
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = configuration.codexHomePath
            process.environment = environment
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
            beginReading(stdout.fileHandleForReading)
            beginReadingErrors(stderr.fileHandleForReading)

            _ = try await request(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "local_codex",
                        "title": "LocalCodex",
                        "version": "0.1.0",
                    ],
                    "capabilities": ["experimentalApi": true],
                ]
            )
            try sendNotification(method: "initialized", params: [:])
            isReady = true
            events.yield(.connectionChanged(.connected(provider: "Codex App Server · LM Studio selected")))
        }

        func submit(prompt: String, taskID: AgentTask.ID) async throws {
            try await start()

            let threadID: String
            if let existing = threadForTask[taskID] {
                threadID = existing
                if !resumedThreads.contains(threadID) {
                    _ = try await request(
                        method: "thread/resume",
                        params: [
                            "threadId": threadID,
                            "modelProvider": configuration.modelProvider,
                            "model": configuration.model,
                            "cwd": configuration.workspacePath,
                            "sandbox": "workspace-write",
                            "approvalPolicy": "on-request",
                            "baseInstructions": configuration.baseInstructions,
                            "config": localThreadConfig(),
                            "excludeTurns": true,
                        ]
                    )
                    resumedThreads.insert(threadID)
                }
            } else {
                let response = try await request(
                    method: "thread/start",
                    params: [
                        "modelProvider": configuration.modelProvider,
                        "model": configuration.model,
                        "cwd": configuration.workspacePath,
                        "sandbox": "workspace-write",
                        "approvalPolicy": "on-request",
                        "ephemeral": false,
                        "threadSource": "local_codex",
                        "baseInstructions": configuration.baseInstructions,
                        "config": localThreadConfig(),
                        "dynamicTools": dynamicToolSpecs(),
                    ]
                )
                threadID = try parseThreadID(from: response)
                threadForTask[taskID] = threadID
                taskForThread[threadID] = taskID
                resumedThreads.insert(threadID)

                let title = String(prompt.prefix(72))
                _ = try? await request(
                    method: "thread/name/set",
                    params: ["threadId": threadID, "name": title]
                )
            }

            _ = try await request(
                method: "turn/start",
                params: [
                    "threadId": threadID,
                    "input": [["type": "text", "text": prompt]],
                    "effort": configuration.reasoningEffort,
                ]
            )
        }

        private func localThreadConfig() -> [String: Any] {
            [
                "memories.use_memories": false,
                "skills.include_instructions": false,
                "include_permissions_instructions": false,
                "include_apps_instructions": false,
                "include_environment_context": false,
                "features.plugins": false,
                "features.apps": false,
                "features.browser_use": false,
                "features.computer_use": false,
                "features.goals": false,
                "features.image_generation": false,
                "features.in_app_browser": false,
                "features.multi_agent": false,
                "features.multi_agent_v2": false,
                "features.shell_tool": false,
                "features.sleep_tool": false,
                "features.unified_exec": false,
                "features.view_image": false,
                "features.workspace_dependencies": false,
                "web_search": "disabled",
                "model_context_window": 4096,
                "model_auto_compact_token_limit": 3584,
            ]
        }

        func loadTasks() async throws -> [AgentTask] {
            let response = try await request(
                method: "thread/list",
                params: [
                    "limit": 100,
                    "modelProviders": [configuration.modelProvider],
                    "archived": false,
                    "sortKey": "recency_at",
                    "sortDirection": "desc",
                ]
            )

            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let result = object["result"] as? [String: Any],
                  let records = result["data"] as? [[String: Any]]
            else {
                throw RuntimeError.malformedResponse("thread/list did not return a thread collection")
            }

            return records.compactMap { record in
                guard let id = record["id"] as? String else { return nil }
                threadForTask[id] = id
                taskForThread[id] = id

                let preview = record["preview"] as? String ?? ""
                let name = record["name"] as? String
                let title = nonEmpty(name) ?? nonEmpty(preview).map { String($0.prefix(72)) } ?? "Untitled task"
                let statusObject = record["status"] as? [String: Any]
                let statusType = statusObject?["type"] as? String
                let status: TaskStatus = switch statusType {
                case "active": .running
                case "idle": .waiting
                default: .completed
                }
                let updatedSeconds = (record["updatedAt"] as? NSNumber)?.doubleValue
                    ?? Date.now.timeIntervalSince1970

                return AgentTask(
                    id: id,
                    title: title,
                    summary: nonEmpty(preview) ?? "Local LM Studio task",
                    status: status,
                    updatedAt: Date(timeIntervalSince1970: updatedSeconds),
                    workspace: record["cwd"] as? String ?? configuration.workspacePath,
                    model: record["model"] as? String ?? configuration.model,
                    entries: []
                )
            }
        }

        func resolveApproval(requestID: String, approved: Bool) throws {
            if let continuation = pendingComputerUseApprovals.removeValue(forKey: requestID) {
                continuation.resume(returning: approved)
                events.yield(.approvalResolved(requestID: requestID))
                return
            }

            guard let pendingApproval = pendingServerApprovals.removeValue(forKey: requestID) else {
                throw RuntimeError.serverError("The approval request is no longer pending.")
            }

            try sendResponse(
                id: pendingApproval.serverRequestID,
                result: ["decision": approved ? "accept" : "decline"]
            )
            events.yield(.approvalResolved(requestID: requestID))

            if let taskID = pendingApproval.request.taskID {
                let outcome = approved ? "Approved" : "Declined"
                events.yield(.timelineEntryAppended(
                    taskID: taskID,
                    entry: TimelineEntry(
                        kind: .tool,
                        title: "\(outcome): \(pendingApproval.request.title)",
                        body: pendingApproval.request.summary,
                        toolEvent: ToolEvent(
                            name: pendingApproval.method,
                            summary: pendingApproval.request.summary,
                            status: approved ? .running : .failed,
                            input: pendingApproval.request.details,
                            output: outcome,
                            duration: nil
                        )
                    )
                ))
            }
        }

        private func beginReading(_ handle: FileHandle) {
            outputHandle = handle
            handle.readabilityHandler = { [weak self] readable in
                let data = readable.availableData
                guard !data.isEmpty else {
                    readable.readabilityHandler = nil
                    Task { await self?.serverEnded() }
                    return
                }
                Task { await self?.receive(output: data) }
            }
        }

        private func beginReadingErrors(_ handle: FileHandle) {
            errorHandle = handle
            handle.readabilityHandler = { readable in
                let data = readable.availableData
                if data.isEmpty {
                    readable.readabilityHandler = nil
                }
                // App Server diagnostics stay on stderr. Reading each available
                // chunk prevents a full pipe from stalling the agent process.
            }
        }

        private func receive(output data: Data) {
            outputBuffer.append(data)

            while let newline = outputBuffer.firstIndex(of: 0x0A) {
                let lineData = outputBuffer[..<newline]
                outputBuffer.removeSubrange(...newline)
                guard !lineData.isEmpty,
                      let line = String(data: lineData, encoding: .utf8)
                else { continue }
                receive(line: line)
            }
        }

        private func receive(line: String) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            if let id = (object["id"] as? NSNumber)?.intValue,
               object["method"] == nil,
               let continuation = pending.removeValue(forKey: id) {
                if let error = object["error"] as? [String: Any] {
                    continuation.resume(
                        throwing: RuntimeError.serverError(
                            (error["message"] as? String) ?? "Codex App Server request failed."
                        )
                    )
                } else {
                    continuation.resume(returning: data)
                }
                return
            }

            guard let method = object["method"] as? String else { return }
            let params = object["params"] as? [String: Any] ?? [:]

            if let id = serverRequestID(from: object["id"]) {
                handleServerRequest(id: id, method: method, params: params)
            } else {
                handleNotification(method: method, params: params)
            }
        }

        private func handleNotification(method: String, params: [String: Any]) {
            guard let threadID = params["threadId"] as? String,
                  let taskID = taskForThread[threadID]
            else { return }

            switch method {
            case "turn/started":
                lastErrorMessageForTask.removeValue(forKey: taskID)
                events.yield(.taskStatusChanged(taskID: taskID, status: .running))

            case "turn/completed":
                let turn = params["turn"] as? [String: Any]
                let status = turn?["status"] as? String
                events.yield(.taskStatusChanged(
                    taskID: taskID,
                    status: status == "completed" ? .completed : .waiting
                ))

            case "item/completed":
                guard let item = params["item"] as? [String: Any],
                      let type = item["type"] as? String
                else { return }
                emitCompletedItem(item, type: type, taskID: taskID)

            case "error":
                let error = params["error"] as? [String: Any]
                let message = error?["message"] as? String
                    ?? params["message"] as? String
                    ?? "The agent reported an error."
                guard lastErrorMessageForTask[taskID] != message else { return }
                lastErrorMessageForTask[taskID] = message
                events.yield(.timelineEntryAppended(
                    taskID: taskID,
                    entry: TimelineEntry(kind: .system, title: "Agent error", body: message)
                ))
                events.yield(.taskStatusChanged(taskID: taskID, status: .waiting))

            default:
                break
            }
        }

        private func emitCompletedItem(
            _ item: [String: Any],
            type: String,
            taskID: AgentTask.ID
        ) {
            let itemID = item["id"] as? String ?? UUID().uuidString

            switch type {
            case "agentMessage":
                guard let text = item["text"] as? String, !text.isEmpty else { return }
                events.yield(.timelineEntryAppended(
                    taskID: taskID,
                    entry: TimelineEntry(
                        id: itemID,
                        kind: .assistant,
                        title: "LocalCodex",
                        body: text
                    )
                ))

            case "reasoning":
                let text = item["summary"] as? String
                    ?? item["text"] as? String
                    ?? "Reasoning completed."
                events.yield(.timelineEntryAppended(
                    taskID: taskID,
                    entry: TimelineEntry(id: itemID, kind: .reasoning, title: "Working", body: text)
                ))

            case "commandExecution", "mcpToolCall", "dynamicToolCall", "webSearch":
                let name = item["name"] as? String ?? type
                let summary = item["command"] as? String
                    ?? item["server"] as? String
                    ?? "\(name) completed"
                events.yield(.timelineEntryAppended(
                    taskID: taskID,
                    entry: TimelineEntry(
                        id: itemID,
                        kind: .tool,
                        title: name,
                        body: summary,
                        toolEvent: ToolEvent(
                            name: name,
                            summary: summary,
                            status: .succeeded,
                            input: prettyJSON(item),
                            output: nil,
                            duration: nil
                        )
                    )
                ))

            default:
                break
            }
        }

        private func handleServerRequest(
            id: ServerRequestID,
            method: String,
            params: [String: Any]
        ) {
            let threadID = params["threadId"] as? String
            let taskID = threadID.flatMap { taskForThread[$0] }

            switch method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                queueApproval(
                    serverRequestID: id,
                    method: method,
                    params: params,
                    taskID: taskID
                )

            case "mcpServer/elicitation/request":
                try? sendResponse(id: id, result: ["action": "decline"])
                emitAutomaticDecline(method: method, params: params, taskID: taskID)

            case "item/tool/requestUserInput":
                try? sendResponse(id: id, result: ["answers": [:]])
                emitAutomaticDecline(method: method, params: params, taskID: taskID)

            case "item/tool/call":
                Task {
                    await handleDynamicToolCall(id: id, params: params, taskID: taskID)
                }

            default:
                try? sendError(id: id, message: "LocalCodex does not yet handle \(method).")
            }
        }

        private func emitAutomaticDecline(
            method: String,
            params: [String: Any],
            taskID: AgentTask.ID?
        ) {
            guard let taskID else { return }
            let summary = "This interactive request type is not supported by LocalCodex yet, so it was declined."
            events.yield(.timelineEntryAppended(
                taskID: taskID,
                entry: TimelineEntry(
                    kind: .tool,
                    title: "Interactive request declined",
                    body: summary,
                    toolEvent: ToolEvent(
                        name: method,
                        summary: summary,
                        status: .failed,
                        input: prettyJSON(params),
                        output: "Declined",
                        duration: nil
                    )
                )
            ))
        }

        private func queueApproval(
            serverRequestID: ServerRequestID,
            method: String,
            params: [String: Any],
            taskID: AgentTask.ID?
        ) {
            let isFileChange = method == "item/fileChange/requestApproval"
            let command = params["command"] as? String
            let reason = params["reason"] as? String
            let cwd = params["cwd"] as? String
            let grantRoot = params["grantRoot"] as? String
            let summary = command
                ?? reason
                ?? (isFileChange ? "The agent wants to modify files." : "The agent wants to run a command.")
            let context = [cwd.map { "Working directory: \($0)" }, grantRoot.map { "Requested root: \($0)" }]
                .compactMap { $0 }
                .joined(separator: "\n")
            let details = [context, prettyJSON(params)]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let approval = ActionApprovalRequest(
                id: UUID().uuidString,
                taskID: taskID,
                kind: isFileChange ? .fileChange : .command,
                title: isFileChange ? "Allow file changes?" : "Run this command?",
                summary: summary,
                details: details
            )
            pendingServerApprovals[approval.id] = PendingServerApproval(
                serverRequestID: serverRequestID,
                method: method,
                request: approval
            )
            events.yield(.approvalRequested(approval))

            if let taskID {
                events.yield(.timelineEntryAppended(
                    taskID: taskID,
                    entry: TimelineEntry(
                        kind: .tool,
                        title: "Approval required",
                        body: approval.summary,
                        toolEvent: ToolEvent(
                            name: method,
                            summary: approval.summary,
                            status: .needsApproval,
                            input: approval.details,
                            output: nil,
                            duration: nil
                        )
                    )
                ))
            }
        }

        private func dynamicToolSpecs() -> [[String: Any]] {
            let emptyObject: [String: Any] = [
                "type": "object",
                "properties": [:],
                "additionalProperties": false,
            ]

            return [
                [
                    "type": "function",
                    "name": "desktop_permission_status",
                    "description": "Read the current macOS Accessibility and Screen Recording permission status without prompting.",
                    "inputSchema": emptyObject,
                ],
                [
                    "type": "function",
                    "name": "desktop_list_apps",
                    "description": "List running macOS applications and their process identifiers. This is read-only.",
                    "inputSchema": emptyObject,
                ],
                [
                    "type": "function",
                    "name": "desktop_focused_window",
                    "description": "Read metadata for the currently focused macOS window. Requires Accessibility permission and never prompts.",
                    "inputSchema": emptyObject,
                ],
                [
                    "type": "function",
                    "name": "desktop_snapshot_app",
                    "description": "Inspect a bounded macOS Accessibility tree for a running application process. Returns stable element indices scoped to one snapshot and never prompts for permission.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "process_id": ["type": "integer", "minimum": 1],
                            "max_depth": ["type": "integer", "minimum": 0, "maximum": 32],
                            "max_elements": ["type": "integer", "minimum": 1, "maximum": 2000],
                        ],
                        "required": ["process_id"],
                        "additionalProperties": false,
                    ],
                ],
                [
                    "type": "function",
                    "name": "desktop_perform_action",
                    "description": "Perform one semantic Accessibility action on an indexed element from the latest snapshot. The GUI always pauses for explicit user approval before acting.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "process_id": ["type": "integer", "minimum": 1],
                            "snapshot_id": ["type": "string"],
                            "element_index": ["type": "integer", "minimum": 0],
                            "action": [
                                "type": "string",
                                "enum": SemanticAXAction.allCases.map(\.rawValue),
                            ],
                        ],
                        "required": ["process_id", "snapshot_id", "element_index", "action"],
                        "additionalProperties": false,
                    ],
                ],
                [
                    "type": "function",
                    "name": "desktop_set_text",
                    "description": "Set text on a settable Accessibility element from the latest snapshot. The GUI always pauses for explicit user approval before acting.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "process_id": ["type": "integer", "minimum": 1],
                            "snapshot_id": ["type": "string"],
                            "element_index": ["type": "integer", "minimum": 0],
                            "text": ["type": "string", "maxLength": 4096],
                        ],
                        "required": ["process_id", "snapshot_id", "element_index", "text"],
                        "additionalProperties": false,
                    ],
                ],
                [
                    "type": "function",
                    "name": "desktop_list_windows",
                    "description": "List capturable macOS windows. Requires Screen Recording permission and never prompts.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "on_screen_only": [
                                "type": "boolean",
                                "description": "When true, omit windows that are currently off screen.",
                            ],
                        ],
                        "additionalProperties": false,
                    ],
                ],
                [
                    "type": "function",
                    "name": "desktop_capture_window",
                    "description": "Capture a PNG screenshot of one window by its window_id. Requires Screen Recording permission and never prompts.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "window_id": ["type": "integer", "minimum": 1],
                            "scale_factor": ["type": "number", "exclusiveMinimum": 0],
                            "shows_cursor": ["type": "boolean"],
                        ],
                        "required": ["window_id"],
                        "additionalProperties": false,
                    ],
                ],
            ]
        }

        private func handleDynamicToolCall(
            id: ServerRequestID,
            params: [String: Any],
            taskID: AgentTask.ID?
        ) async {
            let tool = params["tool"] as? String ?? "unknown"
            let arguments = params["arguments"] as? [String: Any] ?? [:]

            do {
                let contentItems = try await executeDynamicTool(
                    tool,
                    arguments: arguments,
                    taskID: taskID
                )
                try sendResponse(
                    id: id,
                    result: ["contentItems": contentItems, "success": true]
                )
            } catch {
                let message = error.localizedDescription
                try? sendResponse(
                    id: id,
                    result: [
                        "contentItems": [["type": "inputText", "text": message]],
                        "success": false,
                    ]
                )
                if let taskID {
                    events.yield(.timelineEntryAppended(
                        taskID: taskID,
                        entry: TimelineEntry(
                            kind: .tool,
                            title: tool,
                            body: message,
                            toolEvent: ToolEvent(
                                name: tool,
                                summary: message,
                                status: .failed,
                                input: prettyJSON(arguments),
                                output: message,
                                duration: nil
                            )
                        )
                    ))
                }
            }
        }

        private func executeDynamicTool(
            _ tool: String,
            arguments: [String: Any],
            taskID: AgentTask.ID?
        ) async throws -> [[String: Any]] {
            switch tool {
            case "desktop_permission_status":
                return [textContent(try encodeJSON(PermissionInspector().current()))]

            case "desktop_list_apps":
                let applications = await MainActor.run {
                    RunningApplicationCatalog().applications()
                }
                return [textContent(try encodeJSON(applications))]

            case "desktop_focused_window":
                let window = try await MainActor.run {
                    try FocusedWindowReader().focusedWindow()
                }
                return [textContent(try encodeJSON(window))]

            case "desktop_snapshot_app":
                let processID = try requiredProcessID(arguments)
                let defaults = AccessibilityTreeLimits.agentDefault
                let limits = try AccessibilityTreeLimits(
                    maxDepth: (arguments["max_depth"] as? NSNumber)?.intValue ?? defaults.maxDepth,
                    maxElements: (arguments["max_elements"] as? NSNumber)?.intValue ?? defaults.maxElements,
                    maxChildrenPerElement: defaults.maxChildrenPerElement,
                    maxActionsPerElement: defaults.maxActionsPerElement,
                    maxTextLength: defaults.maxTextLength
                )
                let session = AccessibilitySession(processIdentifier: processID)
                let snapshot = try session.snapshot(limits: limits)
                accessibilitySessions[processID] = ActiveAccessibilitySession(
                    session: session,
                    snapshot: snapshot
                )
                return [textContent(try encodeJSON(snapshot))]

            case "desktop_perform_action":
                let processID = try requiredProcessID(arguments)
                let active = try activeAccessibilitySession(
                    processID: processID,
                    snapshotID: try requiredString("snapshot_id", in: arguments)
                )
                let index = try requiredIndex(arguments)
                let actionName = try requiredString("action", in: arguments)
                guard let action = SemanticAXAction(rawValue: actionName) else {
                    throw RuntimeError.serverError("Unsupported semantic Accessibility action: \(actionName)")
                }
                let element = active.snapshot.element(at: index)
                let elementName = element?.title
                    ?? element?.elementDescription
                    ?? element?.role
                    ?? "element \(index)"
                let approved = await requestComputerUseApproval(
                    taskID: taskID,
                    title: "Allow a desktop action?",
                    summary: "\(actionName) on \(elementName)",
                    details: prettyJSON(arguments)
                )
                guard approved else {
                    throw RuntimeError.serverError("The user declined the desktop action.")
                }
                try active.session.perform(action, at: index, in: active.snapshot)
                accessibilitySessions.removeValue(forKey: processID)
                return [textContent("Performed \(actionName) on element \(index). Capture a fresh snapshot before the next action.")]

            case "desktop_set_text":
                let processID = try requiredProcessID(arguments)
                let active = try activeAccessibilitySession(
                    processID: processID,
                    snapshotID: try requiredString("snapshot_id", in: arguments)
                )
                let index = try requiredIndex(arguments)
                let value = try requiredString("text", in: arguments)
                let element = active.snapshot.element(at: index)
                let elementName = element?.title
                    ?? element?.elementDescription
                    ?? element?.role
                    ?? "element \(index)"
                let approved = await requestComputerUseApproval(
                    taskID: taskID,
                    title: "Allow text entry?",
                    summary: "Set text on \(elementName)",
                    details: prettyJSON(arguments)
                )
                guard approved else {
                    throw RuntimeError.serverError("The user declined text entry.")
                }
                try active.session.setValue(.text(value), at: index, in: active.snapshot)
                accessibilitySessions.removeValue(forKey: processID)
                return [textContent("Set text on element \(index). Capture a fresh snapshot before the next action.")]

            case "desktop_list_windows":
                let onScreenOnly = arguments["on_screen_only"] as? Bool ?? true
                let screenshotter = await MainActor.run { WindowScreenshotter() }
                let windows = try await screenshotter.availableWindows(onScreenOnly: onScreenOnly)
                return [textContent(try encodeJSON(windows))]

            case "desktop_capture_window":
                guard let rawWindowID = arguments["window_id"] as? NSNumber else {
                    throw RuntimeError.malformedResponse("desktop_capture_window requires window_id")
                }
                let scale = (arguments["scale_factor"] as? NSNumber)?.doubleValue ?? 1.0
                let showsCursor = arguments["shows_cursor"] as? Bool ?? false
                let screenshotter = await MainActor.run { WindowScreenshotter() }
                let image = try await screenshotter.captureWindow(
                    windowID: rawWindowID.uint32Value,
                    scaleFactor: scale,
                    showsCursor: showsCursor
                )
                guard let png = NSBitmapImageRep(cgImage: image).representation(
                    using: .png,
                    properties: [:]
                ) else {
                    throw RuntimeError.serverError("Could not encode the window screenshot as PNG.")
                }
                return [[
                    "type": "inputImage",
                    "imageUrl": "data:image/png;base64,\(png.base64EncodedString())",
                ]]

            default:
                throw RuntimeError.serverError("Unknown LocalCodex desktop tool: \(tool)")
            }
        }

        private func requestComputerUseApproval(
            taskID: AgentTask.ID?,
            title: String,
            summary: String,
            details: String
        ) async -> Bool {
            let request = ActionApprovalRequest(
                id: UUID().uuidString,
                taskID: taskID,
                kind: .computerUse,
                title: title,
                summary: summary,
                details: details
            )
            return await withCheckedContinuation { continuation in
                pendingComputerUseApprovals[request.id] = continuation
                events.yield(.approvalRequested(request))
            }
        }

        private func requiredProcessID(_ arguments: [String: Any]) throws -> Int32 {
            guard let value = arguments["process_id"] as? NSNumber,
                  value.int64Value > 0,
                  value.int64Value <= Int64(Int32.max)
            else {
                throw RuntimeError.malformedResponse("A valid process_id is required.")
            }
            return value.int32Value
        }

        private func requiredIndex(_ arguments: [String: Any]) throws -> Int {
            guard let value = arguments["element_index"] as? NSNumber, value.intValue >= 0 else {
                throw RuntimeError.malformedResponse("A non-negative element_index is required.")
            }
            return value.intValue
        }

        private func requiredString(
            _ key: String,
            in arguments: [String: Any]
        ) throws -> String {
            guard let value = arguments[key] as? String, !value.isEmpty else {
                throw RuntimeError.malformedResponse("A non-empty \(key) is required.")
            }
            return value
        }

        private func activeAccessibilitySession(
            processID: Int32,
            snapshotID: String
        ) throws -> ActiveAccessibilitySession {
            guard let expectedID = UUID(uuidString: snapshotID),
                  let active = accessibilitySessions[processID],
                  active.snapshot.id == expectedID
            else {
                throw RuntimeError.serverError(
                    "The Accessibility snapshot is missing or stale. Call desktop_snapshot_app again."
                )
            }
            return active
        }

        private func textContent(_ text: String) -> [String: Any] {
            ["type": "inputText", "text": text]
        }

        private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }

        private func request(method: String, params: [String: Any]) async throws -> Data {
            let id = nextRequestID
            nextRequestID += 1

            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try sendObject(["method": method, "id": id, "params": params])
                } catch {
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        }

        private func sendNotification(method: String, params: [String: Any]) throws {
            try sendObject(["method": method, "params": params])
        }

        private func sendResponse(id: ServerRequestID, result: [String: Any]) throws {
            try sendObject(["id": id.jsonValue, "result": result])
        }

        private func sendError(id: ServerRequestID, message: String) throws {
            try sendObject([
                "id": id.jsonValue,
                "error": ["code": -32_601, "message": message],
            ])
        }

        private func serverRequestID(from value: Any?) -> ServerRequestID? {
            if let number = value as? NSNumber {
                return .integer(number.int64Value)
            }
            if let string = value as? String {
                return .string(string)
            }
            return nil
        }

        private func sendObject(_ object: [String: Any]) throws {
            guard let input else { throw RuntimeError.serverStopped }
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try input.write(contentsOf: data)
        }

        private func parseThreadID(from response: Data) throws -> String {
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let result = object["result"] as? [String: Any],
                  let thread = result["thread"] as? [String: Any],
                  let id = thread["id"] as? String
            else {
                throw RuntimeError.malformedResponse("thread/start did not return a thread id")
            }
            return id
        }

        private func prettyJSON(_ value: Any) -> String {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(
                    withJSONObject: value,
                    options: [.prettyPrinted, .sortedKeys]
                  )
            else { return String(describing: value) }
            return String(decoding: data, as: UTF8.self)
        }

        private func nonEmpty(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private func serverEnded() {
            guard process != nil else { return }
            serverFailed(RuntimeError.serverStopped)
        }

        private func serverFailed(_ error: Error) {
            isReady = false
            outputHandle?.readabilityHandler = nil
            errorHandle?.readabilityHandler = nil
            outputHandle = nil
            errorHandle = nil
            outputBuffer.removeAll(keepingCapacity: false)
            process = nil
            input = nil
            let computerUseContinuations = pendingComputerUseApprovals.values
            let unresolvedApprovalIDs = Array(pendingComputerUseApprovals.keys)
                + Array(pendingServerApprovals.keys)
            pendingComputerUseApprovals.removeAll()
            pendingServerApprovals.removeAll()
            accessibilitySessions.removeAll()
            for continuation in computerUseContinuations {
                continuation.resume(returning: false)
            }
            for requestID in unresolvedApprovalIDs {
                events.yield(.approvalResolved(requestID: requestID))
            }
            let continuations = pending.values
            pending.removeAll()
            for continuation in continuations {
                continuation.resume(throwing: error)
            }
            events.yield(.connectionChanged(.failed(message: error.localizedDescription)))
        }
    }
}

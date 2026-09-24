import AppKit
import ApplicationServices
import AutomationCore
@preconcurrency import Foundation

enum AppServerCompletedToolItemContract {
    static func status(for item: [String: Any]) -> ToolRunStatus {
        if let success = item["success"] as? Bool, !success {
            return .failed
        }

        switch item["status"] as? String {
        case "failed", "declined":
            return .failed
        case "inProgress":
            return .running
        default:
            return .succeeded
        }
    }

    static func summary(for item: [String: Any], name: String) -> String {
        if let command = item["command"] as? String {
            return command
        }
        if let server = item["server"] as? String {
            return server
        }

        switch status(for: item) {
        case .failed:
            return failureMessage(in: item) ?? "\(name) failed"
        case .running:
            return "\(name) is running"
        case .succeeded, .needsApproval:
            return "\(name) completed"
        }
    }

    private static func failureMessage(in item: [String: Any]) -> String? {
        if let error = item["error"] as? String, !error.isEmpty {
            return error
        }
        if let error = item["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty
        {
            return message
        }
        guard let contentItems = item["contentItems"] as? [[String: Any]] else {
            return nil
        }
        return contentItems.compactMap { contentItem in
            guard contentItem["type"] as? String == "inputText" else { return nil }
            return contentItem["text"] as? String
        }.first(where: { !$0.isEmpty })
    }
}

enum ComputerToolContract {
    static let maximumSemanticTextLength = 4_096

    static func accessibilityTarget(
        processIdentifier: Int32,
        runningApplications: [RunningApplicationInfo]
    ) -> AccessibilityApplicationTarget? {
        let matches = runningApplications.filter {
            $0.processIdentifier == processIdentifier && !$0.isTerminated
        }
        guard matches.count == 1, let application = matches.first else {
            return nil
        }
        return AccessibilityApplicationTarget(application: application)
    }
}

enum ComputerToolArgumentContract {
    enum ValidationError: LocalizedError, Equatable {
        case parametersMustBeObject
        case ambiguousProcessID
        case invalidProcessID

        var errorDescription: String? {
            switch self {
            case .parametersMustBeObject:
                "computer parameters must be a JSON object; do not send a JSON-encoded string."
            case .ambiguousProcessID:
                "Supply only one of process_id or pid, not both."
            case .invalidProcessID:
                "A valid numeric process_id (or pid) is required."
            }
        }
    }

    static func parameters(in arguments: [String: Any]) throws -> [String: Any] {
        guard let rawParameters = arguments["parameters"] else { return [:] }
        guard let parameters = rawParameters as? [String: Any] else {
            throw ValidationError.parametersMustBeObject
        }
        return parameters
    }

    static func requiredProcessID(_ arguments: [String: Any]) throws -> Int32 {
        let hasProcessID = arguments.keys.contains("process_id")
        let hasPID = arguments.keys.contains("pid")
        guard !(hasProcessID && hasPID) else {
            throw ValidationError.ambiguousProcessID
        }
        let rawValue = hasProcessID ? arguments["process_id"] : arguments["pid"]
        guard let integer = exactInt64(rawValue),
              integer > 0,
              let processID = Int32(exactly: integer)
        else {
            throw ValidationError.invalidProcessID
        }
        return processID
    }

    static func finiteDouble(_ rawValue: Any?) -> Double? {
        guard let number = rawValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else {
            return nil
        }
        return number.doubleValue
    }

    static func exactInt64(_ rawValue: Any?) -> Int64? {
        guard let number = rawValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else {
            return nil
        }
        let value = number.int64Value
        guard number.compare(NSNumber(value: value)) == .orderedSame else {
            return nil
        }
        return value
    }

    static func optionalStringArray(_ rawValue: Any?) -> [String]? {
        guard let rawValue else { return [] }
        return rawValue as? [String]
    }
}

enum ComputerV2TargetContract {
    enum TargetRegionError: Error, Equatable {
        case invalidGeometry
        case pointOutsideWindow
    }

    private static func sameFrame(
        _ left: WindowFrame,
        _ right: WindowFrame,
        tolerance: Double
    ) -> Bool {
        [left.x, left.y, left.width, left.height,
         right.x, right.y, right.width, right.height].allSatisfy(\.isFinite)
            && abs(left.x - right.x) <= tolerance
            && abs(left.y - right.y) <= tolerance
            && abs(left.width - right.width) <= tolerance
            && abs(left.height - right.height) <= tolerance
    }

    static func isRunning(
        _ bound: ActivatedApplication,
        in applications: [RunningApplicationInfo]
    ) -> Bool {
        applications.filter {
            $0.processIdentifier == bound.processIdentifier
                && $0.bundleIdentifier == bound.bundleIdentifier
                && !$0.isTerminated
        }.count == 1
    }

    static func contains(_ point: ScreenPoint, in frame: WindowFrame) -> Bool {
        frame.x.isFinite && frame.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
            && (frame.x + frame.width).isFinite
            && (frame.y + frame.height).isFinite
            && point.x.isFinite && point.y.isFinite
            && point.x >= frame.x && point.x < frame.x + frame.width
            && point.y >= frame.y && point.y < frame.y + frame.height
    }

    /// A bounded neighborhood of the intended input target in the specified
    /// capture frame. V2 uses it for both the window image and the separate
    /// downscaled display baseline. This rejects a changed button or
    /// same-sized navigation without treating a
    /// clock or animation elsewhere in the window as a changed target.
    static func targetPixelRegion(
        for points: [ScreenPoint],
        windowFrame: WindowFrame,
        imageWidth: Int,
        imageHeight: Int,
        radius: Int = 128
    ) throws -> CGRect {
        guard !points.isEmpty,
              imageWidth > 0, imageHeight > 0,
              radius > 0,
              windowFrame.x.isFinite, windowFrame.y.isFinite,
              windowFrame.width.isFinite, windowFrame.height.isFinite,
              windowFrame.width > 0, windowFrame.height > 0,
              (windowFrame.x + windowFrame.width).isFinite,
              (windowFrame.y + windowFrame.height).isFinite
        else { throw TargetRegionError.invalidGeometry }

        var minX = imageWidth
        var minY = imageHeight
        var maxX = 0
        var maxY = 0
        for point in points {
            guard contains(point, in: windowFrame) else {
                throw TargetRegionError.pointOutsideWindow
            }
            let imageX = (point.x - windowFrame.x) * Double(imageWidth) / windowFrame.width
            let imageY = (point.y - windowFrame.y) * Double(imageHeight) / windowFrame.height
            guard imageX.isFinite, imageY.isFinite,
                  imageX >= 0, imageY >= 0,
                  imageX < Double(imageWidth), imageY < Double(imageHeight)
            else { throw TargetRegionError.invalidGeometry }
            let x = Int(imageX.rounded(.down))
            let y = Int(imageY.rounded(.down))
            minX = min(minX, max(0, x - radius))
            minY = min(minY, max(0, y - radius))
            maxX = max(maxX, min(imageWidth, x + radius + 1))
            maxY = max(maxY, min(imageHeight, y + radius + 1))
        }
        guard maxX > minX, maxY > minY else {
            throw TargetRegionError.invalidGeometry
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func isSameFocusedWindow(
        _ current: FocusedWindowInfo?,
        as capturedFrame: WindowFrame,
        for bound: ActivatedApplication
    ) -> Bool {
        guard let current,
              current.processIdentifier == bound.processIdentifier,
              current.bundleIdentifier == bound.bundleIdentifier,
              let frame = current.frame
        else { return false }
        return sameFrame(frame, capturedFrame, tolerance: 2)
    }

    static func matchingWindow(
        for focused: FocusedWindowInfo,
        in windows: [CapturableWindowInfo]
    ) -> CapturableWindowInfo? {
        guard let frame = focused.frame else { return nil }
        let matches = windows.filter {
            $0.isOnScreen
                && $0.owningProcessIdentifier == focused.processIdentifier
                && $0.owningBundleIdentifier == focused.bundleIdentifier
                && sameFrame($0.frame, frame, tolerance: 8)
        }
        // AX and ScreenCaptureKit can describe the same Chrome window with
        // different titles. Cross-API title equality is not a reliable
        // identity check; require a unique PID/bundle/frame match instead.
        // Subsequent checks retain the SC window ID, fingerprint, and exact
        // focused AX window identity before any approved input.
        return matches.count == 1 ? matches[0] : nil
    }

    static func isSameWindow(
        _ current: CapturableWindowInfo?,
        as captured: CapturableWindowInfo
    ) -> Bool {
        guard let current else { return false }
        return current.windowID == captured.windowID
            && current.isOnScreen
            && current.owningProcessIdentifier == captured.owningProcessIdentifier
            && current.owningBundleIdentifier == captured.owningBundleIdentifier
            && (current.title == nil || captured.title == nil || current.title == captured.title)
            && sameFrame(current.frame, captured.frame, tolerance: 2)
    }
}

enum ComputerV2FreshnessPolicy {
    /// A model-grounded coordinate depends on the context of the whole image,
    /// so an unchanged target crop is insufficient proof. Explicit coordinates
    /// retain the smaller target-region check to tolerate unrelated animation.
    static func windowFingerprintTargets(
        _ targetPoints: [ScreenPoint],
        usesVisualGrounding: Bool
    ) -> [ScreenPoint] {
        usesVisualGrounding ? [] : targetPoints
    }
}

enum LocalThreadContext: Equatable, Sendable {
    case constrained
    case expanded

    static func forModel(_ modelID: String) -> Self {
        switch modelID {
        case "lmstudio-community/Qwen3.5-9B-MLX-4bit",
             "lmstudio-community/Qwen3.5-4B-MLX-4bit":
            .expanded
        default:
            // Keep the validated 27B limit, and use it for unvalidated models.
            .constrained
        }
    }

    var contextWindow: Int {
        switch self {
        case .constrained: 4096
        case .expanded: 8192
        }
    }

    var autoCompactTokenLimit: Int {
        switch self {
        case .constrained: 3584
        case .expanded: 7168
        }
    }

    func supportsModelSwitch(to modelID: String) -> Bool {
        self == Self.forModel(modelID)
    }
}

/// A small native client for the open-source Codex App Server protocol.
///
/// App Server owns the agent loop, thread state, MCP startup, sandboxing, and
/// tool execution. This adapter keeps JSON-RPC out of the SwiftUI layer and
/// deliberately declines approval requests until the GUI presents them.
final class CodexAppServerRuntime: AgentRuntimeClient, @unchecked Sendable {
    static func localThreadConfig(for modelID: String) -> [String: Any] {
        let context = LocalThreadContext.forModel(modelID)
        return [
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
            "model_context_window": context.contextWindow,
            "model_auto_compact_token_limit": context.autoCompactTokenLimit,
        ]
    }

    struct Configuration: Sendable {
        var executablePath: String
        var modelProvider: String
        var model: String
        var workspacePath: String
        var codexHomePath: String
        var baseInstructions: String
        var reasoningEffort: String
        /// Optional raw NDJSON recorder for protocol-level integration tests.
        /// The production app leaves this nil so prompts and tool payloads are
        /// never copied into a second log by LocalCodex.
        var protocolTracePath: String? = nil

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
                model: LocalModelCatalog.defaultModelID,
                workspacePath: documents,
                codexHomePath: codexHome.path,
                baseInstructions: """
                You are LocalCodex, a concise local desktop agent. Follow the request precisely. For computer use, observe with Accessibility or a screenshot, act only through the provided desktop tools, then observe again. Prefer semantic Accessibility. A Chrome URL opened by computer_v2_open is an exact task-scoped tab; use its semantic snapshot and actions because browser coordinates and keyboard input fail closed. In native apps, computer_v2_capture can include synchronized Accessibility. Use snapshot_id for semantic actions and capture_id for image actions. Never estimate coordinates. Accessibility frames are screen points, not image pixels. Chrome is com.google.Chrome. Respect approvals and never infer success from an action acknowledgment. An available POST_ACTION_OBSERVATION includes a fresh screenshot and synchronized Accessibility; verify the visible outcome in its content, not its marker. Request another observation only if unavailable or inconclusive.
                """,
                reasoningEffort: "medium"
            )
        }
    }

    nonisolated let providerName = "Codex App Server (LM Studio selected)"

    private let core: Core
    private let eventStream: AsyncStream<AgentRuntimeEvent>

    init(
        configuration: Configuration,
        browserBroker: ChromeTabBroker = ChromeTabBroker(),
        visualGrounder: any VisualGroundingClient = PythonVisualGroundingClient.local()
    ) {
        var continuation: AsyncStream<AgentRuntimeEvent>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        core = Core(
            configuration: configuration,
            events: continuation!,
            browserBroker: browserBroker,
            visualGrounder: visualGrounder
        )
    }

    func loadTasks() async throws -> [AgentTask] {
        try await core.start()
        return try await core.loadTasks()
    }

    func events() -> AsyncStream<AgentRuntimeEvent> {
        eventStream
    }

    func submit(prompt: String, toTaskID taskID: AgentTask.ID, modelID: String) async throws {
        try await core.submit(prompt: prompt, taskID: taskID, modelID: modelID)
    }

    func interrupt(taskID: AgentTask.ID) async throws {
        try await core.interrupt(taskID: taskID)
    }

    func resolveApproval(requestID: String, approved: Bool) async throws {
        try await core.resolveApproval(requestID: requestID, approved: approved)
    }

    func shutdown() async -> RuntimeShutdownReport {
        await core.shutdown()
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

        private struct DynamicToolTask {
            let taskID: AgentTask.ID?
            let task: Task<Void, Never>
        }

        private struct ActiveAccessibilitySession {
            let session: AccessibilitySession
            let snapshot: AccessibilityTreeSnapshot
        }

        private struct ComputerV2Capture {
            let mapper: ScreenshotCoordinateMapper
            let displayID: UInt32
            let displayFrame: WindowFrame
            let displayImage: CGImage
            let showsCursor: Bool
            let focusedWindowFrame: WindowFrame
            let focusedWindowIdentity: FocusedWindowIdentity
            let window: CapturableWindowInfo
            let windowImage: CGImage
            let fingerprint: WindowCaptureFingerprint
        }

        private struct ComputerV2Session {
            let epoch: UUID
            var application: ActivatedApplication?
            var accessibility: ActiveAccessibilitySession?
            var accessibilityWindowIdentity: FocusedWindowIdentity?
            var capture: ComputerV2Capture?
            var browserTab: BrowserTabBinding?
            var browserSnapshot: BrowserTabSnapshot?
            var browserLifetime: BrowserTabLifetime?
        }

        private enum DesktopInputAction {
            case move(ScreenPoint)
            case click(ScreenPoint)
            case doubleClick(ScreenPoint)
            case rightClick(ScreenPoint)
            case scroll(point: ScreenPoint, deltaX: Int32, deltaY: Int32)
            case drag(start: ScreenPoint, end: ScreenPoint, duration: Double)
            case keypress(KeyboardChord, keyName: String)
            case type(String)

            var name: String {
                switch self {
                case .move: "move"
                case .click: "click"
                case .doubleClick: "double_click"
                case .rightClick: "right_click"
                case .scroll: "scroll"
                case .drag: "drag"
                case .keypress: "keypress"
                case .type: "type"
                }
            }

            var summary: String {
                switch self {
                case .move(let point):
                    return "Move the pointer to (\(point.x), \(point.y))"
                case .click(let point):
                    return "Click at (\(point.x), \(point.y))"
                case .doubleClick(let point):
                    return "Double-click at (\(point.x), \(point.y))"
                case .rightClick(let point):
                    return "Right-click at (\(point.x), \(point.y))"
                case .scroll(let point, let deltaX, let deltaY):
                    return "Scroll at (\(point.x), \(point.y)) by (\(deltaX), \(deltaY)) pixels"
                case .drag(let start, let end, let duration):
                    return "Drag from (\(start.x), \(start.y)) to (\(end.x), \(end.y)) over \(duration) seconds"
                case .keypress(let chord, let keyName):
                    let modifiers = chord.modifiers.map(\.rawValue).sorted().joined(separator: "+")
                    return "Press " + ([modifiers, keyName].filter { !$0.isEmpty }.joined(separator: "+"))
                case .type(let text):
                    return "Type \(text.count) characters"
                }
            }

            var pointerTargets: [ScreenPoint] {
                switch self {
                case .move(let point), .click(let point),
                     .doubleClick(let point), .rightClick(let point):
                    return [point]
                case .scroll(let point, _, _):
                    return [point]
                case .drag(let start, let end, _):
                    return [start, end]
                case .keypress, .type:
                    return []
                }
            }
        }

        enum RuntimeError: LocalizedError {
            case executableMissing(String)
            case serverStopped
            case malformedResponse(String)
            case serverError(String)
            case contextChangeRequiresNewTask

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
                case .contextChangeRequiresNewTask:
                    "Codex App Server cannot change this task's context window while its thread is loaded. Create a new task for the selected model."
                }
            }
        }

        private let configuration: Configuration
        private let events: AsyncStream<AgentRuntimeEvent>.Continuation
        private let browserBroker: ChromeTabBroker
        private let visualGrounder: any VisualGroundingClient

        private var process: OwnedChildProcess?
        private var input: FileHandle?
        private var outputHandle: FileHandle?
        private var errorHandle: FileHandle?
        private var protocolTraceHandle: FileHandle?
        private var protocolTraceSequence = 0
        private var outputBuffer = Data()
        private var nextRequestID = 1
        private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
        private var dynamicToolTasks = [ServerRequestID: DynamicToolTask]()
        private var threadForTask: [AgentTask.ID: String] = [:]
        private var taskForThread: [String: AgentTask.ID] = [:]
        private var turnForTask: [AgentTask.ID: String] = [:]
        private var modelForTask: [AgentTask.ID: String] = [:]
        private var contextForLoadedThread: [String: LocalThreadContext] = [:]
        private var lastErrorMessageForTask: [AgentTask.ID: String] = [:]
        private var pendingServerApprovals: [String: PendingServerApproval] = [:]
        private var pendingComputerUseApprovals: [String: CheckedContinuation<Bool, Never>] = [:]
        private var computerApprovalTask: [String: AgentTask.ID] = [:]
        private var accessibilitySessions: [Int32: ActiveAccessibilitySession] = [:]
        private var computerV2Sessions: [AgentTask.ID: ComputerV2Session] = [:]
        private var computerV2InFlight: [AgentTask.ID: UUID] = [:]
        private var computerGlobalInFlight: UUID?
        private var isReady = false
        private var isStartingServer = false
        private var isShuttingDown = false
        private var serverGeneration = UUID()
        private var shutdownTask: Task<RuntimeShutdownReport, Never>?
        private var visualGrounderPreparationTask: Task<Void, Never>?
        private var visualGrounderPreparationID: UUID?
        private var visualGroundingResidency = VisualGroundingResidencyGate()
        private var retiringChildren = [Int32: OwnedChildProcess]()
        private var childCleanupIssues = [String]()
        private var browserCleanupTasks = [UUID: Task<Void, Never>]()

        init(
            configuration: Configuration,
            events: AsyncStream<AgentRuntimeEvent>.Continuation,
            browserBroker: ChromeTabBroker,
            visualGrounder: any VisualGroundingClient
        ) {
            self.configuration = configuration
            self.events = events
            self.browserBroker = browserBroker
            self.visualGrounder = visualGrounder
        }

        func start() async throws {
            guard !isShuttingDown else { throw RuntimeError.serverStopped }
            guard !isReady else { return }
            guard !isStartingServer else {
                throw RuntimeError.serverError("The App Server is still starting.")
            }
            isStartingServer = true
            defer { isStartingServer = false }
            guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else {
                throw RuntimeError.executableMissing(configuration.executablePath)
            }
            events.yield(.connectionChanged(.connecting))
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            try FileManager.default.createDirectory(
                atPath: configuration.codexHomePath,
                withIntermediateDirectories: true
            )
            if let protocolTracePath = configuration.protocolTracePath {
                try startProtocolTrace(atPath: protocolTracePath)
            }
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = configuration.codexHomePath
            let process = try OwnedChildProcess(
                executableURL: URL(fileURLWithPath: configuration.executablePath),
                arguments: ["app-server", "--listen", "stdio://"],
                environment: environment,
                inputDescriptor: stdin.fileHandleForReading.fileDescriptor,
                outputDescriptor: stdout.fileHandleForWriting.fileDescriptor,
                errorDescriptor: stderr.fileHandleForWriting.fileDescriptor
            )
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            self.process = process
            serverGeneration = UUID()
            input = stdin.fileHandleForWriting
            beginReading(stdout.fileHandleForReading)
            beginReadingErrors(stderr.fileHandleForReading)
            do {
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
                guard !isShuttingDown, self.process === process else {
                    throw RuntimeError.serverStopped
                }
                try sendNotification(method: "initialized", params: [:])
                isReady = true
                events.yield(.connectionChanged(.connected(provider: "Codex App Server · LM Studio selected")))
            } catch {
                if self.process === process { serverFailed(error) }
                throw error
            }
        }

        func shutdown() async -> RuntimeShutdownReport {
            if let shutdownTask { return await shutdownTask.value }
            isShuttingDown = true
            // Revokes all task lifetimes and approval continuations synchronously.
            serverFailed(RuntimeError.serverStopped)
            let task = Task { await self.finishShutdown() }
            shutdownTask = task
            return await task.value
        }

        private func finishShutdown() async -> RuntimeShutdownReport {
            await cancelVisualGrounderPreparation()
            let children = Array(retiringChildren.values)
            async let browserResult = browserBroker.shutdown()
            async let groundingIssues = visualGrounder.shutdown()
            let processIssues = await withTaskGroup(of: [String].self) { group in
                for child in children {
                    group.addTask { await child.stop().issues }
                }
                var issues = [String]()
                for await result in group { issues.append(contentsOf: result) }
                return issues
            }
            let browser = await browserResult
            let grounder = await groundingIssues
            let issues = Array(Set(
                processIssues + childCleanupIssues + browser.issues + grounder
            )).sorted()
            for cleanup in browserCleanupTasks.values { cleanup.cancel() }
            browserCleanupTasks.removeAll()
            events.yield(.connectionChanged(.disconnected))
            events.finish()
            return RuntimeShutdownReport(issues: issues)
        }

        @discardableResult
        private func scheduleBrowserCleanup(
            taskID: AgentTask.ID,
            binding: BrowserTabBinding
        ) -> Task<Void, Never> {
            binding.lifetime.revoke()
            let key = browserTaskKey(taskID)
            let id = UUID()
            let cleanup = Task<Void, Never> {
                await browserBroker.revoke(taskKey: key, binding: binding)
                browserCleanupTasks.removeValue(forKey: id)
            }
            browserCleanupTasks[id] = cleanup
            return cleanup
        }

        @discardableResult
        private func discardComputerV2Session(taskID: AgentTask.ID) -> Task<Void, Never>? {
            let session = computerV2Sessions.removeValue(forKey: taskID)
            session?.browserLifetime?.revoke()
            session?.browserTab?.lifetime.revoke()
            let requestIDs = computerApprovalTask.compactMap { $0.value == taskID ? $0.key : nil }
            for requestID in requestIDs {
                computerApprovalTask.removeValue(forKey: requestID)
                pendingComputerUseApprovals.removeValue(forKey: requestID)?.resume(returning: false)
                events.yield(.approvalResolved(requestID: requestID))
            }
            let serverApprovals = pendingServerApprovals.filter { $0.value.request.taskID == taskID }
            for (requestID, approval) in serverApprovals {
                pendingServerApprovals.removeValue(forKey: requestID)
                try? sendResponse(id: approval.serverRequestID, result: ["decision": "decline"])
                events.yield(.approvalResolved(requestID: requestID))
            }
            guard let binding = session?.browserTab else { return nil }
            return scheduleBrowserCleanup(taskID: taskID, binding: binding)
        }

        func submit(prompt: String, taskID: AgentTask.ID, modelID: String) async throws {
            try await start()
            let supportsVisualGrounding = LocalModelCatalog.supportsResidentVisualGrounding(modelID)
            guard visualGroundingResidency.reserve(
                taskID: taskID,
                supportsSidecar: supportsVisualGrounding
            ) else {
                throw RuntimeError.serverError(
                    "A turn using the other local-model memory profile is already running. "
                        + "Wait for it to finish before switching between the 4B/9B visual "
                        + "sidecar profile and the 27B/35B high-memory profile."
                )
            }
            var turnAccepted = false
            defer {
                if !turnAccepted {
                    visualGroundingResidency.release(taskID: taskID)
                }
            }
            let requestedContext = LocalThreadContext.forModel(modelID)

            let threadID: String
            if let existing = threadForTask[taskID] {
                threadID = existing
                if let loadedContext = contextForLoadedThread[threadID] {
                    // App Server ignores config overrides when thread/resume
                    // rejoins a loaded thread; turn/start has no config field.
                    guard loadedContext.supportsModelSwitch(to: modelID) else {
                        throw RuntimeError.contextChangeRequiresNewTask
                    }
                } else {
                    _ = try await request(
                        method: "thread/resume",
                        params: [
                            "threadId": threadID,
                            "modelProvider": configuration.modelProvider,
                            "model": modelID,
                            "cwd": configuration.workspacePath,
                            "sandbox": "workspace-write",
                            "approvalPolicy": "on-request",
                            "baseInstructions": baseInstructions(for: modelID),
                            "config": CodexAppServerRuntime.localThreadConfig(for: modelID),
                            "excludeTurns": true,
                        ]
                    )
                    contextForLoadedThread[threadID] = requestedContext
                }
            } else {
                let response = try await request(
                    method: "thread/start",
                    params: [
                        "modelProvider": configuration.modelProvider,
                        "model": modelID,
                        "cwd": configuration.workspacePath,
                        "sandbox": "workspace-write",
                        "approvalPolicy": "on-request",
                        "ephemeral": false,
                        "threadSource": "local_codex",
                        "baseInstructions": baseInstructions(for: modelID),
                        "config": CodexAppServerRuntime.localThreadConfig(for: modelID),
                        "dynamicTools": dynamicToolSpecs(for: modelID),
                    ]
                )
                threadID = try parseThreadID(from: response)
                threadForTask[taskID] = threadID
                taskForThread[threadID] = taskID
                contextForLoadedThread[threadID] = requestedContext

                let title = String(prompt.prefix(72))
                _ = try? await request(
                    method: "thread/name/set",
                    params: ["threadId": threadID, "name": title]
                )
            }

            // Bindings and screenshot coordinates are valid for one turn only.
            // A resumed thread must observe and bind its target again.
            discardComputerV2Session(taskID: taskID)
            computerV2Sessions[taskID] = ComputerV2Session(epoch: UUID())

            let previousModel = modelForTask.updateValue(modelID, forKey: taskID)
            let turnResponse: Data
            do {
                if !supportsVisualGrounding {
                    try await suspendVisualGrounderForHighMemoryModel()
                }
                turnResponse = try await request(
                    method: "turn/start",
                    params: [
                        "threadId": threadID,
                        "input": [["type": "text", "text": prompt]],
                        "effort": configuration.reasoningEffort,
                        "model": modelID,
                    ]
                )
            } catch {
                if let previousModel {
                    modelForTask[taskID] = previousModel
                } else {
                    modelForTask.removeValue(forKey: taskID)
                }
                throw error
            }
            turnAccepted = true
            if supportsVisualGrounding {
                // Start only after App Server accepts the turn so a rejected
                // submission cannot load and retain the multi-GB sidecar.
                prepareVisualGrounderInBackground()
            }
            if let object = try JSONSerialization.jsonObject(with: turnResponse) as? [String: Any],
               let result = object["result"] as? [String: Any],
               let turn = result["turn"] as? [String: Any],
               let turnID = turn["id"] as? String {
                turnForTask[taskID] = turnID
            }
        }

        func interrupt(taskID: AgentTask.ID) async throws {
            guard let threadID = threadForTask[taskID],
                  let turnID = turnForTask[taskID] else {
                throw RuntimeError.serverError("This task has no active turn to stop.")
            }
            // Revocation precedes both the RPC and every cleanup await.
            let cleanup = discardComputerV2Session(taskID: taskID)
            let toolTasks = cancelDynamicToolTasks(for: taskID)
            for task in toolTasks { await task.value }
            _ = try await request(
                method: "turn/interrupt",
                params: ["threadId": threadID, "turnId": turnID]
            )
            await cleanup?.value
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

            let tasks = records.compactMap { record -> AgentTask? in
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

                let modelID = record["model"] as? String ?? configuration.model
                modelForTask[id] = modelID
                if status == .running {
                    visualGroundingResidency.restoreActive(
                        taskID: id,
                        supportsSidecar: LocalModelCatalog.supportsResidentVisualGrounding(modelID)
                    )
                }
                return AgentTask(
                    id: id,
                    title: title,
                    summary: nonEmpty(preview) ?? "Local LM Studio task",
                    status: status,
                    updatedAt: Date(timeIntervalSince1970: updatedSeconds),
                    workspace: record["cwd"] as? String ?? configuration.workspacePath,
                    model: modelID,
                    entries: []
                )
            }
            if tasks.contains(where: {
                $0.status == .running
                    && LocalModelCatalog.supportsResidentVisualGrounding($0.model)
            }) {
                prepareVisualGrounderInBackground()
            }
            return tasks
        }

        func resolveApproval(requestID: String, approved: Bool) throws {
            if let continuation = pendingComputerUseApprovals.removeValue(forKey: requestID) {
                computerApprovalTask.removeValue(forKey: requestID)
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
            let generation = serverGeneration
            outputHandle = handle
            handle.readabilityHandler = { [weak self] readable in
                let data = readable.availableData
                guard !data.isEmpty else {
                    readable.readabilityHandler = nil
                    Task { await self?.serverEnded(generation: generation) }
                    return
                }
                Task { await self?.receive(output: data, generation: generation) }
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

        private func receive(output data: Data, generation: UUID) {
            guard !isShuttingDown, generation == serverGeneration, process != nil else { return }
            outputBuffer.append(data)

            while let newline = outputBuffer.firstIndex(of: 0x0A) {
                let lineData = Data(outputBuffer[..<newline])
                let wireData = Data(outputBuffer[...newline])
                outputBuffer.removeSubrange(...newline)
                recordProtocolBytes(wireData, direction: "server_to_client")
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
            guard !isShuttingDown else { return }
            guard let threadID = params["threadId"] as? String,
                  let taskID = taskForThread[threadID]
            else { return }

            switch method {
            case "turn/started":
                if let turn = params["turn"] as? [String: Any],
                   let turnID = turn["id"] as? String {
                    turnForTask[taskID] = turnID
                }
                discardComputerV2Session(taskID: taskID)
                computerV2Sessions[taskID] = ComputerV2Session(epoch: UUID())
                lastErrorMessageForTask.removeValue(forKey: taskID)
                events.yield(.taskStatusChanged(taskID: taskID, status: .running))

            case "turn/completed":
                turnForTask.removeValue(forKey: taskID)
                visualGroundingResidency.release(taskID: taskID)
                discardComputerV2Session(taskID: taskID)
                _ = cancelDynamicToolTasks(for: taskID)
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
                visualGroundingResidency.release(taskID: taskID)
                discardComputerV2Session(taskID: taskID)
                _ = cancelDynamicToolTasks(for: taskID)
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
                let name = item["name"] as? String
                    ?? item["tool"] as? String
                    ?? type
                let status = AppServerCompletedToolItemContract.status(for: item)
                let summary = AppServerCompletedToolItemContract.summary(for: item, name: name)
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
                            status: status,
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
                let generation = serverGeneration
                let operation = Task {
                    defer { dynamicToolTasks.removeValue(forKey: id) }
                    guard !isShuttingDown, generation == serverGeneration else { return }
                    await handleDynamicToolCall(id: id, params: params, taskID: taskID)
                }
                dynamicToolTasks[id] = DynamicToolTask(taskID: taskID, task: operation)

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

        private func dynamicToolSpecs(for modelID: String) -> [[String: Any]] {
            // Existing rollouts retain their original dynamic-tool definition
            // on resume. New threads use a model-aware V2 contract so the 27B
            // and 35B models are never offered a resident sidecar they cannot
            // safely fit beside.
            ComputerV2ToolContract.specs(for: modelID)
        }

        private func prepareVisualGrounderInBackground() {
            guard visualGroundingResidency.allowsSidecar,
                  visualGrounderPreparationTask == nil else { return }
            let preparationID = UUID()
            visualGrounderPreparationID = preparationID
            visualGrounderPreparationTask = Task { [visualGrounder] in
                try? await visualGrounder.prepare()
                self.visualGrounderPreparationFinished(id: preparationID)
            }
        }

        private func visualGrounderPreparationFinished(id: UUID) {
            guard visualGrounderPreparationID == id else { return }
            visualGrounderPreparationID = nil
            visualGrounderPreparationTask = nil
        }

        private func cancelVisualGrounderPreparation() async {
            let preparation = visualGrounderPreparationTask
            visualGrounderPreparationID = nil
            visualGrounderPreparationTask = nil
            preparation?.cancel()
            await preparation?.value
        }

        private func suspendVisualGrounderForHighMemoryModel() async throws {
            await cancelVisualGrounderPreparation()
            let issues = await visualGrounder.shutdown()
            guard issues.isEmpty else {
                throw RuntimeError.serverError(
                    "The visual-grounding sidecar could not be stopped before loading this "
                        + "high-memory model: \(issues.joined(separator: "; "))"
                )
            }
        }

        private func baseInstructions(for modelID: String) -> String {
            let groundingInstruction: String
            if LocalModelCatalog.supportsResidentVisualGrounding(modelID) {
                groundingInstruction = """
                If a visible native target is absent from Accessibility, use \
                computer_v2_ground_click with the exact capture_id and a concise target \
                description. It returns a fresh post-action screenshot with synchronized \
                Accessibility when available; verify the visible outcome in that result rather \
                than inferring success from action dispatch.
                """
            } else {
                groundingInstruction = """
                Visual grounding is not offered with this model because the resident \
                sidecar would exceed this Mac's safe memory budget; use Accessibility.
                """
            }
            return configuration.baseInstructions + "\n" + groundingInstruction
        }

        private func handleDynamicToolCall(
            id: ServerRequestID,
            params: [String: Any],
            taskID: AgentTask.ID?
        ) async {
            let generation = serverGeneration
            let tool = params["tool"] as? String ?? "unknown"
            let arguments = params["arguments"] as? [String: Any] ?? [:]

            do {
                let contentItems = try await executeDynamicTool(
                    tool,
                    arguments: arguments,
                    taskID: taskID
                )
                guard !Task.isCancelled,
                      !isShuttingDown,
                      generation == serverGeneration else { return }
                try sendResponse(
                    id: id,
                    result: ["contentItems": contentItems, "success": true]
                )
            } catch {
                guard !Task.isCancelled,
                      !isShuttingDown,
                      generation == serverGeneration else { return }
                let message = error.localizedDescription
                try? sendResponse(
                    id: id,
                    result: [
                        "contentItems": [["type": "inputText", "text": message]],
                        "success": false,
                    ]
                )
            }
        }

        private func executeDynamicTool(
            _ tool: String,
            arguments: [String: Any],
            taskID: AgentTask.ID?
        ) async throws -> [[String: Any]] {
            if tool.hasPrefix("computer_v2_") {
                return try await executeComputerV2(tool, arguments: arguments, taskID: taskID)
            }
            switch tool {
            case "computer":
                guard computerGlobalInFlight == nil else {
                    throw RuntimeError.serverError(
                        "Another computer action is still pending. Try again after it completes."
                    )
                }
                let operationID = UUID()
                computerGlobalInFlight = operationID
                defer {
                    if computerGlobalInFlight == operationID {
                        computerGlobalInFlight = nil
                    }
                }
                let action = try requiredString("action", in: arguments)
                var parameters = try ComputerToolArgumentContract.parameters(in: arguments)
                let mappedTool: String
                switch action {
                case "permission_status":
                    mappedTool = "desktop_permission_status"
                case "open":
                    mappedTool = "desktop_open_application"
                case "apps":
                    mappedTool = "desktop_list_apps"
                case "snapshot":
                    mappedTool = "desktop_snapshot_app"
                case "ax":
                    mappedTool = "desktop_perform_action"
                    parameters["action"] = try requiredString("ax_action", in: parameters)
                case "set_text":
                    mappedTool = "desktop_set_text"
                case "capture":
                    mappedTool = "desktop_capture_display"
                case "move", "click", "double_click", "right_click", "scroll", "drag", "keypress", "type":
                    mappedTool = "desktop_input"
                    parameters["action"] = action
                default:
                    throw RuntimeError.serverError("Unknown computer action: \(action)")
                }
                return try await executeDynamicTool(
                    mappedTool,
                    arguments: parameters,
                    taskID: taskID
                )

            case "desktop_permission_status":
                return [textContent(try encodeJSON(PermissionInspector().current()))]

            case "desktop_open_application":
                let bundleIdentifier = try requiredString("bundle_id", in: arguments)
                guard bundleIdentifier.count <= 255,
                      bundleIdentifier.unicodeScalars.allSatisfy({
                          CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
                      })
                else {
                    throw RuntimeError.malformedResponse("bundle_id is not a valid application identifier")
                }
                let url = try optionalOpenURL(arguments["url"])
                let summary = url.map {
                    "Open \(bundleIdentifier) at \($0.absoluteString)"
                } ?? "Launch or activate \(bundleIdentifier)"
                let approved = await requestComputerUseApproval(
                    taskID: taskID,
                    title: "Allow an application action?",
                    summary: summary,
                    details: prettyJSON(arguments)
                )
                guard approved else {
                    throw RuntimeError.serverError("The user declined the application action.")
                }
                let controller = await MainActor.run { ComputerInputController() }
                let application = try await controller.launchOrActivateApplication(
                    bundleIdentifier: bundleIdentifier,
                    opening: url
                )
                return [textContent(
                    try encodeJSON(application)
                        + "\nApplication action completed. Observe the app before interacting with it."
                )]

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
                let result = try await makeAccessibilitySnapshot(
                    processID: processID,
                    arguments: arguments
                )
                accessibilitySessions[processID] = result.active
                return [textContent(result.text)]

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
                defer { accessibilitySessions.removeValue(forKey: processID) }
                try await prepareAccessibilityMutation(
                    active,
                    processIdentifier: processID
                )
                try active.session.refreshAndPerform(
                    action,
                    at: index,
                    in: active.snapshot
                )
                return [textContent("Requested \(actionName) on element \(index). Capture a fresh snapshot to verify the result before the next action.")]

            case "desktop_set_text":
                let processID = try requiredProcessID(arguments)
                let active = try activeAccessibilitySession(
                    processID: processID,
                    snapshotID: try requiredString("snapshot_id", in: arguments)
                )
                let index = try requiredIndex(arguments)
                let value = try requiredString("text", in: arguments)
                guard value.count <= ComputerToolContract.maximumSemanticTextLength else {
                    throw RuntimeError.malformedResponse(
                        "text must be at most \(ComputerToolContract.maximumSemanticTextLength) characters"
                    )
                }
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
                defer { accessibilitySessions.removeValue(forKey: processID) }
                try await prepareAccessibilityMutation(
                    active,
                    processIdentifier: processID
                )
                try active.session.refreshAndSetValue(
                    .text(value),
                    at: index,
                    in: active.snapshot
                )
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
                guard scale.isFinite, (0.25 ... 1.0).contains(scale) else {
                    throw RuntimeError.malformedResponse("scale_factor must be between 0.25 and 1")
                }
                let showsCursor = arguments["shows_cursor"] as? Bool ?? false
                let screenshotter = await MainActor.run { WindowScreenshotter() }
                let windows = try await screenshotter.availableWindows(onScreenOnly: false)
                guard let window = windows.first(where: { $0.windowID == rawWindowID.uint32Value }) else {
                    throw RuntimeError.serverError("No capturable window has ID \(rawWindowID.uint32Value).")
                }
                let image = try await screenshotter.captureWindow(
                    windowID: rawWindowID.uint32Value,
                    scaleFactor: scale,
                    showsCursor: showsCursor
                )
                let metadata = """
                WINDOW_CAPTURE window=\(try encodeJSON(window))
                image_width=\(image.width) image_height=\(image.height) coordinate_space=global_screen_points
                Map image coordinates with screen_x=frame.x+(image_x*frame.width/image_width) and screen_y=frame.y+(image_y*frame.height/image_height).
                """
                return [textContent(metadata), try imageContent(image)]

            case "desktop_capture_display":
                let displayID = try optionalUInt32("display_id", in: arguments)
                let showsCursor = arguments["shows_cursor"] as? Bool ?? false
                let screenshotter = await MainActor.run { DisplayScreenshotter() }
                let displays = try await screenshotter.availableDisplays()
                let selectedDisplay: CapturableDisplayInfo?
                if let displayID {
                    selectedDisplay = displays.first { $0.displayID == displayID }
                } else {
                    selectedDisplay = displays.first(where: \.isMain) ?? displays.first
                }
                guard let selectedDisplay else {
                    throw RuntimeError.serverError("The requested display is not available.")
                }
                let limits = try DisplayCaptureLimits(
                    // The loaded Qwen runtime has a real 4K context. A full
                    // Retina display at the previous size consumed most of the
                    // remaining window as vision tokens, leaving too little
                    // room for a click and verification. This still preserves
                    // enough detail for ordinary controls while fitting one
                    // visual observation into a practical tool turn.
                    maximumWidth: 896,
                    maximumHeight: 720,
                    maximumPixelCount: 600_000
                )
                let image = try await screenshotter.captureDisplay(
                    displayID: selectedDisplay.displayID,
                    limits: limits,
                    showsCursor: showsCursor
                )
                let metadata = """
                DISPLAY_CAPTURE selected=\(try encodeJSON(selectedDisplay))
                displays=\(try encodeJSON(displays))
                image_width=\(image.width) image_height=\(image.height) coordinate_space=global_screen_points
                Map image coordinates with screen_x=frame.x+(image_x*frame.width/image_width) and screen_y=frame.y+(image_y*frame.height/image_height).
                """
                return [textContent(metadata), try imageContent(image)]

            case "desktop_input":
                let processID = try requiredProcessID(arguments)
                let action = try parseDesktopInputAction(arguments)
                let approved = await requestComputerUseApproval(
                    taskID: taskID,
                    title: "Allow computer input?",
                    summary: action.summary,
                    details: prettyJSON(arguments)
                )
                guard approved else {
                    throw RuntimeError.serverError("The user declined computer input.")
                }
                let controller = await MainActor.run { ComputerInputController() }
                _ = try await controller.activateApplication(processIdentifier: processID)
                try await perform(action, using: controller)
                return [textContent(
                    "Completed \(action.name). Capture a fresh Accessibility snapshot or screenshot to verify the result."
                )]

            default:
                throw RuntimeError.serverError("Unknown LocalCodex desktop tool: \(tool)")
            }
        }

        private func cancelDynamicToolTasks(
            for taskID: AgentTask.ID
        ) -> [Task<Void, Never>] {
            let matches = dynamicToolTasks.filter { $0.value.taskID == taskID }
            for (id, operation) in matches {
                dynamicToolTasks.removeValue(forKey: id)
                operation.task.cancel()
            }
            return matches.map(\.value.task)
        }

        private func makeAccessibilitySnapshot(
            processID: Int32,
            arguments: [String: Any]
        ) async throws -> (active: ActiveAccessibilitySession, text: String) {
            let preferredText: String?
            if let rawQuery = arguments["query"] {
                guard let query = rawQuery as? String,
                      !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      query.count <= 200
                else {
                    throw RuntimeError.malformedResponse(
                        "query must be a non-empty string of at most 200 characters"
                    )
                }
                preferredText = query
            } else {
                preferredText = nil
            }
            let defaults = AccessibilityTreeLimits.agentDefault
            // Targeted lookups search a larger bounded tree but return less text.
            let defaultElementLimit = preferredText == nil ? 240 : 1_000
            let maximumElementLimit = preferredText == nil ? 400 : 1_000
            let requestedElementLimit = (arguments["max_elements"] as? NSNumber)?.intValue
                ?? defaultElementLimit
            let limits = try AccessibilityTreeLimits(
                maxDepth: (arguments["max_depth"] as? NSNumber)?.intValue ?? defaults.maxDepth,
                maxElements: min(requestedElementLimit, maximumElementLimit),
                maxChildrenPerElement: defaults.maxChildrenPerElement,
                maxActionsPerElement: 12,
                maxTextLength: ComputerToolContract.maximumSemanticTextLength
            )
            let runningApplications = await MainActor.run {
                RunningApplicationCatalog().applications()
            }
            guard let target = ComputerToolContract.accessibilityTarget(
                processIdentifier: processID,
                runningApplications: runningApplications
            ) else {
                throw RuntimeError.serverError(
                    "The selected application process is no longer available. Call desktop_list_apps again."
                )
            }
            let session = AccessibilitySession(target: target)
            let snapshot = try session.snapshot(limits: limits)
            let active = ActiveAccessibilitySession(session: session, snapshot: snapshot)
            let formatter = AccessibilitySnapshotTextFormatter(
                elementLimit: limits.maxElements,
                fieldCharacterLimit: 72,
                actionLimit: 6,
                outputCharacterLimit: preferredText == nil ? 3_000 : 1_000,
                prioritizesRelevantElements: true,
                preferredText: preferredText,
                usesCompactElementLines: true
            )
            return (active, snapshot.formattedForModel(using: formatter))
        }

        private func computerV2Session(
            taskID: AgentTask.ID,
            epoch: UUID
        ) throws -> ComputerV2Session {
            guard let session = computerV2Sessions[taskID], session.epoch == epoch else {
                throw RuntimeError.serverError(
                    "This computer-use turn is no longer active. Start a fresh turn and observe again."
                )
            }
            return session
        }

        private func computerV2BoundApplication(
            taskID: AgentTask.ID,
            epoch: UUID
        ) async throws -> ActivatedApplication {
            guard let application = try computerV2Session(
                taskID: taskID,
                epoch: epoch
            ).application else {
                throw RuntimeError.serverError(
                    "No application is bound in this turn. Call computer_v2_open first."
                )
            }
            let running = await MainActor.run {
                RunningApplicationCatalog().applications()
            }
            _ = try computerV2Session(taskID: taskID, epoch: epoch)
            guard ComputerV2TargetContract.isRunning(application, in: running) else {
                computerV2Sessions[taskID]?.application = nil
                computerV2Sessions[taskID]?.accessibility = nil
                computerV2Sessions[taskID]?.accessibilityWindowIdentity = nil
                computerV2Sessions[taskID]?.capture = nil
                computerV2Sessions[taskID]?.browserLifetime?.revoke()
                if let binding = computerV2Sessions[taskID]?.browserTab {
                    scheduleBrowserCleanup(taskID: taskID, binding: binding)
                }
                computerV2Sessions[taskID]?.browserLifetime = nil
                computerV2Sessions[taskID]?.browserTab = nil
                computerV2Sessions[taskID]?.browserSnapshot = nil
                throw RuntimeError.serverError(
                    "The bound application changed or quit. Open it again before interacting."
                )
            }
            return application
        }

        private func computerV2ApprovalDetails(
            arguments: [String: Any],
            application: ActivatedApplication,
            browserTab: BrowserTabBinding? = nil,
            observedPageURL: URL? = nil
        ) -> String {
            var target: [String: Any] = [
                "bundle_id": application.bundleIdentifier,
                "process_id": application.processIdentifier,
            ]
            if let browserTab {
                target["tab_handle"] = browserTab.handle.uuidString
                target["document_epoch"] = browserTab.documentEpoch.uuidString
                if let observedPageURL {
                    target["observed_page_url"] = observedPageURL.absoluteString
                }
            }
            return prettyJSON([
                "model_arguments": arguments,
                "resolved_target": target,
            ])
        }

        private func browserTaskKey(_ taskID: AgentTask.ID) -> String {
            String(describing: taskID)
        }

        private func clearComputerV2Observation(taskID: AgentTask.ID, epoch: UUID) throws {
            var session = try computerV2Session(taskID: taskID, epoch: epoch)
            session.accessibility = nil
            session.accessibilityWindowIdentity = nil
            session.capture = nil
            session.browserSnapshot = nil
            computerV2Sessions[taskID] = session
        }

        private func computerV2FocusedWindowObservation() async throws -> FocusedWindowObservation? {
            // AX's system-wide focused-application query can briefly return
            // cannotComplete while AppKit hands activation from the native
            // approval overlay to the opened app. Observation may wait for
            // that handoff; pre-input checks below never retry or retarget.
            for attempt in 0 ..< 20 {
                do {
                    return try await MainActor.run {
                        try FocusedWindowReader().focusedWindowObservation()
                    }
                } catch AutomationError.accessibilityFailure(_, let code)
                    where code == AXError.cannotComplete.rawValue && attempt < 19 {
                    try await Task.sleep(for: .milliseconds(25))
                }
            }
            return nil
        }

        private func executeComputerV2(
            _ tool: String,
            arguments: [String: Any],
            taskID: AgentTask.ID?
        ) async throws -> [[String: Any]] {
            guard let taskID else {
                throw RuntimeError.serverError("Computer use requires a known task and thread.")
            }
            // LM Studio currently accepts strict JSON schemas but can still
            // emit missing fields. Validation here, before approval, is the
            // actual enforcement boundary.
            let call = try ComputerV2ToolContract.validate(
                tool: tool,
                arguments: arguments
            )
            guard computerV2InFlight[taskID] == nil else {
                throw RuntimeError.serverError(
                    "Another computer action is still pending for this task."
                )
            }
            let needsDesktopIsolation = call.tool != .status && call.tool != .apps
            guard !needsDesktopIsolation || computerGlobalInFlight == nil else {
                throw RuntimeError.serverError(
                    "Another computer action is still pending. Try again after it completes."
                )
            }
            let operationID = UUID()
            computerV2InFlight[taskID] = operationID
            if needsDesktopIsolation {
                computerGlobalInFlight = operationID
            }
            defer {
                if computerV2InFlight[taskID] == operationID {
                    computerV2InFlight.removeValue(forKey: taskID)
                }
                if computerGlobalInFlight == operationID {
                    computerGlobalInFlight = nil
                }
            }
            guard let epoch = computerV2Sessions[taskID]?.epoch else {
                throw RuntimeError.serverError(
                    "This computer-use turn is not active. Start a fresh turn."
                )
            }

            switch call.tool {
            case .status:
                return [textContent(try encodeJSON(PermissionInspector().current()))]

            case .apps:
                let applications = await MainActor.run {
                    RunningApplicationCatalog().applications()
                }
                _ = try computerV2Session(taskID: taskID, epoch: epoch)
                return [textContent(try encodeJSON(applications))]

            case .open:
                return try await computerV2Open(
                    arguments: arguments,
                    taskID: taskID,
                    epoch: epoch
                )

            case .snapshot:
                return try await computerV2Snapshot(
                    arguments: arguments,
                    taskID: taskID,
                    epoch: epoch
                )

            case .ax, .setText:
                return try await computerV2SemanticAction(
                    call,
                    taskID: taskID,
                    epoch: epoch
                )

            case .capture:
                return try await computerV2Capture(
                    arguments: arguments,
                    taskID: taskID,
                    epoch: epoch
                )

            case .groundClick:
                return try await computerV2GroundedClickAction(
                    call,
                    taskID: taskID,
                    epoch: epoch
                )

            case .click, .pointer:
                return try await computerV2PointerAction(
                    call,
                    taskID: taskID,
                    epoch: epoch
                )

            case .keypress, .type:
                return try await computerV2KeyboardAction(
                    call,
                    taskID: taskID,
                    epoch: epoch
                )
            }
        }

        private func computerV2Snapshot(
            arguments: [String: Any],
            taskID: AgentTask.ID,
            epoch: UUID
        ) async throws -> [[String: Any]] {
            let application = try await computerV2BoundApplication(
                taskID: taskID,
                epoch: epoch
            )
            let currentSession = try computerV2Session(
                taskID: taskID,
                epoch: epoch
            )
            if let browserTab = currentSession.browserTab {
                let observation = try await browserBroker.snapshot(
                    taskKey: browserTaskKey(taskID),
                    binding: browserTab,
                    query: arguments["query"] as? String
                )
                _ = try await computerV2BoundApplication(
                    taskID: taskID,
                    epoch: epoch
                )
                var session = try computerV2Session(taskID: taskID, epoch: epoch)
                guard session.browserTab?.handle == browserTab.handle else {
                    throw RuntimeError.serverError(
                        "The bound browser tab changed during snapshot. Open it again."
                    )
                }
                session.browserTab = observation.binding
                session.browserSnapshot = observation.snapshot
                session.accessibility = nil
                session.accessibilityWindowIdentity = nil
                session.capture = nil
                computerV2Sessions[taskID] = session
                return [textContent(observation.snapshot.formattedText)]
            }

            let focusedObservation = try await computerV2FocusedWindowObservation()
            guard let focusedObservation,
                  focusedObservation.info.processIdentifier == application.processIdentifier,
                  focusedObservation.info.bundleIdentifier == application.bundleIdentifier else {
                throw RuntimeError.serverError(
                    "The bound app does not have the focused window. Open it again before snapshot."
                )
            }
            let result = try await makeAccessibilitySnapshot(
                processID: application.processIdentifier,
                arguments: arguments
            )
            _ = try await computerV2BoundApplication(taskID: taskID, epoch: epoch)
            guard try await focusedObservation.identity.isStillFocused() else {
                throw RuntimeError.serverError(
                    "The focused window changed during snapshot. Observe again."
                )
            }
            var session = try computerV2Session(taskID: taskID, epoch: epoch)
            session.accessibility = result.active
            session.accessibilityWindowIdentity = focusedObservation.identity
            session.capture = nil
            session.browserSnapshot = nil
            computerV2Sessions[taskID] = session
            return [textContent(result.text)]
        }

        private func computerV2Open(
            arguments: [String: Any],
            taskID: AgentTask.ID,
            epoch: UUID
        ) async throws -> [[String: Any]] {
            let bundleID = try requiredString("bundle_id", in: arguments)
            let url = try optionalOpenURL(arguments["url"])
            let summary = url.map {
                "Open \(bundleID) at \($0.absoluteString)"
            } ?? "Launch or activate \(bundleID)"
            let approved = await requestComputerUseApproval(
                taskID: taskID,
                title: "Allow an application action?",
                summary: summary,
                details: prettyJSON(arguments)
            )
            guard approved else {
                throw RuntimeError.serverError("The user declined the application action.")
            }

            var pendingSession = try computerV2Session(taskID: taskID, epoch: epoch)
            let oldBinding = pendingSession.browserTab
            pendingSession.browserLifetime?.revoke()
            oldBinding?.lifetime.revoke()
            pendingSession.application = nil
            pendingSession.accessibility = nil
            pendingSession.accessibilityWindowIdentity = nil
            pendingSession.capture = nil
            pendingSession.browserTab = nil
            pendingSession.browserSnapshot = nil
            let lifetime = bundleID == "com.google.Chrome" && url != nil
                ? BrowserTabLifetime() : nil
            pendingSession.browserLifetime = lifetime
            computerV2Sessions[taskID] = pendingSession
            if let oldBinding {
                await browserBroker.revoke(taskKey: browserTaskKey(taskID), binding: oldBinding)
            }

            var createdBinding: BrowserTabBinding?
            do {
                _ = try computerV2Session(taskID: taskID, epoch: epoch)
                let controller = await MainActor.run { ComputerInputController() }
                _ = try computerV2Session(taskID: taskID, epoch: epoch)
                let application: ActivatedApplication
                if let lifetime, let url {
                    let opened = try await browserBroker.open(
                        taskKey: browserTaskKey(taskID), url: url, lifetime: lifetime
                    )
                    createdBinding = opened.binding
                    _ = try computerV2Session(taskID: taskID, epoch: epoch)
                    try lifetime.check()
                    application = try await controller.activateApplication(
                        processIdentifier: opened.application.processIdentifier
                    )
                } else {
                    application = try await controller.launchOrActivateApplication(
                        bundleIdentifier: bundleID, opening: url
                    )
                }
                _ = try computerV2Session(taskID: taskID, epoch: epoch)
                guard application.bundleIdentifier == bundleID,
                      createdBinding == nil
                        || createdBinding?.processIdentifier == application.processIdentifier else {
                    throw RuntimeError.serverError(
                        "The launched process did not match the approved application."
                    )
                }
                let running = await MainActor.run {
                    RunningApplicationCatalog().applications()
                }
                _ = try computerV2Session(taskID: taskID, epoch: epoch)
                try lifetime?.check()
                guard ComputerV2TargetContract.isRunning(application, in: running) else {
                    throw RuntimeError.serverError("The approved application is no longer running.")
                }
                var session = try computerV2Session(taskID: taskID, epoch: epoch)
                session.application = application
                session.browserTab = createdBinding
                session.browserLifetime = lifetime
                computerV2Sessions[taskID] = session
                let browserNote = createdBinding.map {
                    "\nBROWSER_TAB tab_handle=\($0.handle.uuidString) "
                        + "document_epoch=\($0.documentEpoch.uuidString) "
                        + "scope=current_task semantic_background_actions=true "
                        + "profile=isolated ordinary_profile_access=false"
                } ?? ""
                let navigationNote = url == nil ? "" :
                    " URL navigation may still be loading; if the first snapshot lacks page content, take another snapshot before acting."
                return [textContent(
                    try encodeJSON(application)
                        + "\nBound this app for the current turn. Observe before acting; no process ID is needed."
                        + browserNote
                        + navigationNote
                )]
            } catch {
                lifetime?.revoke()
                if let createdBinding {
                    await browserBroker.revoke(
                        taskKey: browserTaskKey(taskID), binding: createdBinding
                    )
                }
                throw error
            }
        }

        private func computerV2SemanticAction(
            _ call: ComputerV2ToolContract.ValidatedCall,
            taskID: AgentTask.ID,
            epoch: UUID
        ) async throws -> [[String: Any]] {
            let application = try await computerV2BoundApplication(
                taskID: taskID,
                epoch: epoch
            )
            let currentSession = try computerV2Session(
                taskID: taskID,
                epoch: epoch
            )
            if currentSession.browserTab != nil {
                return try await computerV2BrowserSemanticAction(
                    call,
                    application: application,
                    taskID: taskID,
                    epoch: epoch
                )
            }
            guard let active = try computerV2Session(
                taskID: taskID,
                epoch: epoch
            ).accessibility,
                  let windowIdentity = try computerV2Session(
                      taskID: taskID,
                      epoch: epoch
                  ).accessibilityWindowIdentity,
                  let snapshotID = UUID(uuidString: try requiredString(
                      "snapshot_id",
                      in: call.arguments
                  )),
                  active.snapshot.id == snapshotID
            else {
                throw RuntimeError.serverError(
                    "The Accessibility snapshot is missing or stale. Capture a fresh snapshot."
                )
            }
            let index = try requiredIndex(call.arguments)
            let element = active.snapshot.element(at: index)
            let elementName = element?.title
                ?? element?.elementDescription
                ?? element?.role
                ?? "element \(index)"

            let summary: String
            let title: String
            let semanticAction: SemanticAXAction?
            let textValue: String?
            if call.tool == .ax {
                let actionName = try requiredString("ax_action", in: call.arguments)
                semanticAction = SemanticAXAction(rawValue: actionName)
                textValue = nil
                summary = "\(actionName) on \(elementName)"
                title = "Allow a desktop action?"
            } else {
                semanticAction = nil
                textValue = try requiredString("text", in: call.arguments)
                summary = "Set text on \(elementName)"
                title = "Allow text entry?"
            }
            let approved = await requestComputerUseApproval(
                taskID: taskID,
                title: title,
                summary: summary,
                details: computerV2ApprovalDetails(
                    arguments: call.arguments,
                    application: application
                )
            )
            guard approved else {
                throw RuntimeError.serverError("The user declined the desktop action.")
            }
            _ = try await computerV2BoundApplication(taskID: taskID, epoch: epoch)
            guard try computerV2Session(taskID: taskID, epoch: epoch)
                .accessibility?.snapshot.id == snapshotID else {
                throw RuntimeError.serverError(
                    "The approved Accessibility snapshot is no longer current."
                )
            }
            try await prepareAccessibilityMutation(
                active,
                processIdentifier: application.processIdentifier
            )
            _ = try await computerV2BoundApplication(taskID: taskID, epoch: epoch)
            guard try await windowIdentity.isStillFocused() else {
                throw RuntimeError.serverError(
                    "The inspected window changed before the approved action. Observe again."
                )
            }
            try clearComputerV2Observation(taskID: taskID, epoch: epoch)
            if let semanticAction {
                try active.session.refreshAndPerform(
                    semanticAction,
                    at: index,
                    in: active.snapshot
                )
            } else if let textValue {
                try active.session.refreshAndSetValue(
                    .text(textValue),
                    at: index,
                    in: active.snapshot
                )
            }
            return [textContent(
                "Requested \(summary). Capture a fresh snapshot to verify the result."
            )]
        }

        private func computerV2BrowserSemanticAction(
            _ call: ComputerV2ToolContract.ValidatedCall,
            application: ActivatedApplication,
            taskID: AgentTask.ID,
            epoch: UUID
        ) async throws -> [[String: Any]] {
            let current = try computerV2Session(taskID: taskID, epoch: epoch)
            guard let browserTab = current.browserTab,
                  let browserSnapshot = current.browserSnapshot,
                  let snapshotID = UUID(
                      uuidString: try requiredString("snapshot_id", in: call.arguments)
                  ),
                  snapshotID == browserSnapshot.id,
                  browserSnapshot.tabHandle == browserTab.handle,
                  browserSnapshot.documentEpoch == browserTab.documentEpoch else {
                throw RuntimeError.serverError(
                    "The browser Accessibility snapshot is missing or stale. Capture a fresh snapshot."
                )
            }

            let index = try requiredIndex(call.arguments)
            guard let element = browserSnapshot.element(at: index) else {
                throw RuntimeError.serverError(
                    "The browser Accessibility element is no longer available."
                )
            }
            let elementName = element.label.isEmpty
                ? "\(element.role) element \(index)" : element.label

            let summary: String
            let title: String
            let actionName: String?
            let textValue: String?
            if call.tool == .ax {
                let requestedAction = try requiredString(
                    "ax_action",
                    in: call.arguments
                )
                actionName = requestedAction
                textValue = nil
                summary = "\(requestedAction) on \(elementName)"
                title = "Allow a desktop action?"
            } else {
                actionName = nil
                textValue = try requiredString("text", in: call.arguments)
                summary = "Set text on \(elementName)"
                title = "Allow text entry?"
            }

            let approved = await requestComputerUseApproval(
                taskID: taskID,
                title: title,
                summary: summary,
                details: computerV2ApprovalDetails(
                    arguments: call.arguments,
                    application: application,
                    browserTab: browserTab,
                    observedPageURL: browserSnapshot.documentURL
                )
            )
            guard approved else {
                throw RuntimeError.serverError("The user declined the browser action.")
            }

            _ = try await computerV2BoundApplication(taskID: taskID, epoch: epoch)
            let approvedSession = try computerV2Session(taskID: taskID, epoch: epoch)
            guard approvedSession.browserTab == browserTab,
                  approvedSession.browserSnapshot == browserSnapshot else {
                throw RuntimeError.serverError(
                    "The approved browser target is no longer current."
                )
            }

            try clearComputerV2Observation(taskID: taskID, epoch: epoch)
            if let actionName {
                try await browserBroker.perform(
                    taskKey: browserTaskKey(taskID),
                    binding: browserTab,
                    snapshot: browserSnapshot,
                    elementIndex: index,
                    action: actionName
                )
            } else if let textValue {
                try await browserBroker.setText(
                    taskKey: browserTaskKey(taskID),
                    binding: browserTab,
                    snapshot: browserSnapshot,
                    elementIndex: index,
                    text: textValue
                )
            }

            return [textContent(
                "Requested \(summary) on the exact bound browser tab. "
                    + "Capture a fresh snapshot to verify the result."
            )]
        }

        private func computerV2Capture(
            arguments: [String: Any],
            taskID: AgentTask.ID,
            epoch: UUID
        ) async throws -> [[String: Any]] {
            let includeAccessibility = arguments["include_accessibility"] as? Bool ?? false
            let application = try await computerV2BoundApplication(
                taskID: taskID,
                epoch: epoch
            )
            guard try computerV2Session(
                taskID: taskID,
                epoch: epoch
            ).browserTab == nil else {
                throw RuntimeError.serverError(
                    "Screenshot and coordinate tools are unavailable for a brokered Chrome tab. "
                        + "Use a semantic browser snapshot and action."
                )
            }
            let focusedObservation = try await computerV2FocusedWindowObservation()
            guard let focusedObservation else {
                throw RuntimeError.serverError(
                    "The bound app does not have the focused window. Open it again before capture."
                )
            }
            let focused = focusedObservation.info
            guard focused.processIdentifier == application.processIdentifier,
                  focused.bundleIdentifier == application.bundleIdentifier,
                  let focusedFrame = focused.frame else {
                throw RuntimeError.serverError(
                    "The bound app does not have the focused window. Open it again before capture."
                )
            }
            let center = ScreenPoint(
                x: focusedFrame.x + focusedFrame.width / 2,
                y: focusedFrame.y + focusedFrame.height / 2
            )
            let windowScreenshotter = await MainActor.run { WindowScreenshotter() }
            let windowsBefore = try await windowScreenshotter.availableWindows()
            guard let window = ComputerV2TargetContract.matchingWindow(
                for: focused,
                in: windowsBefore
            ) else {
                throw RuntimeError.serverError(
                    "The focused app window could not be identified uniquely. Observe again."
                )
            }
            let screenshotter = await MainActor.run { DisplayScreenshotter() }
            let displays = try await screenshotter.availableDisplays()
            let selectedDisplay: CapturableDisplayInfo?
            if let displayID = try optionalUInt32("display_id", in: arguments) {
                selectedDisplay = displays.first { $0.displayID == displayID }
            } else {
                selectedDisplay = displays.first {
                    ComputerV2TargetContract.contains(center, in: $0.frame)
                }
            }
            guard let selectedDisplay,
                  ComputerV2TargetContract.contains(center, in: selectedDisplay.frame)
            else {
                throw RuntimeError.serverError(
                    "The focused window is not on the selected display. Capture it again."
                )
            }
            let limits = try DisplayCaptureLimits(
                maximumWidth: 896,
                maximumHeight: 720,
                maximumPixelCount: 600_000
            )
            let showsCursor = arguments["shows_cursor"] as? Bool ?? false
            let displayImage = try await screenshotter.captureDisplay(
                displayID: selectedDisplay.displayID,
                limits: limits,
                showsCursor: showsCursor
            )
            let focusedAfter = try await MainActor.run {
                try FocusedWindowReader().focusedWindow()
            }
            let windowsAfter = try await windowScreenshotter.availableWindows()
            guard ComputerV2TargetContract.isSameWindow(
                windowsAfter.first(where: { $0.windowID == window.windowID }),
                as: window
            ) else {
                throw RuntimeError.serverError(
                    "The app window changed during capture. Observe again."
                )
            }
            let windowImageAfter = try await windowScreenshotter.captureWindow(
                windowID: window.windowID,
                scaleFactor: 1
            )
            let fingerprintAfter = try WindowCaptureFingerprint.make(from: windowImageAfter)
            let windowsAfterImage = try await windowScreenshotter.availableWindows()
            guard let stableWindow = windowsAfterImage.first(where: {
                $0.windowID == window.windowID
            }),
                  ComputerV2TargetContract.isSameWindow(stableWindow, as: window),
                  stableWindow.frame == window.frame else {
                throw RuntimeError.serverError(
                    "The app window changed during capture. Observe again."
                )
            }
            _ = try await computerV2BoundApplication(taskID: taskID, epoch: epoch)
            guard ComputerV2TargetContract.isSameFocusedWindow(
                focusedAfter,
                as: focusedFrame,
                for: application
            ), try await focusedObservation.identity.isStillFocused() else {
                throw RuntimeError.serverError(
                    "The focused window changed during capture. Capture a fresh screenshot."
                )
            }
            let mapper = try ScreenshotCoordinateMapper(
                frame: window.frame,
                imageWidth: windowImageAfter.width,
                imageHeight: windowImageAfter.height,
                captureID: UUID(),
                capturedAt: Date()
            )
            var accessibilityObservation: (active: ActiveAccessibilitySession, text: String)?
            if includeAccessibility {
                let observed = try await makeAccessibilitySnapshot(
                    processID: application.processIdentifier,
                    arguments: [:]
                )
                _ = try await computerV2BoundApplication(taskID: taskID, epoch: epoch)
                guard try await focusedObservation.identity.isStillFocused() else {
                    throw RuntimeError.serverError(
                        "The focused window changed while combining screenshot and Accessibility. Observe again."
                    )
                }
                let windowsAfterAccessibility = try await windowScreenshotter.availableWindows()
                guard let currentWindow = windowsAfterAccessibility.first(where: {
                    $0.windowID == window.windowID
                }),
                      ComputerV2TargetContract.isSameWindow(currentWindow, as: window),
                      currentWindow.frame == window.frame else {
                    throw RuntimeError.serverError(
                        "The app window changed while combining screenshot and Accessibility. Observe again."
                    )
                }
                let imageAfterAccessibility = try await windowScreenshotter.captureWindow(
                    windowID: window.windowID,
                    scaleFactor: 1
                )
                guard try WindowCaptureFingerprint.make(from: imageAfterAccessibility)
                    == fingerprintAfter else {
                    throw RuntimeError.serverError(
                        "The app image changed while combining screenshot and Accessibility. Observe again."
                    )
                }
                accessibilityObservation = observed
            }
            var session = try computerV2Session(taskID: taskID, epoch: epoch)
            session.accessibility = accessibilityObservation?.active
            session.accessibilityWindowIdentity = accessibilityObservation == nil
                ? nil : focusedObservation.identity
            session.capture = ComputerV2Capture(
                mapper: mapper,
                displayID: selectedDisplay.displayID,
                displayFrame: selectedDisplay.frame,
                displayImage: displayImage,
                showsCursor: showsCursor,
                focusedWindowFrame: focusedFrame,
                focusedWindowIdentity: focusedObservation.identity,
                window: window,
                windowImage: windowImageAfter,
                fingerprint: fingerprintAfter
            )
            computerV2Sessions[taskID] = session
            var content = [textContent(ComputerV2ToolContract.captureMetadata(mapper: mapper))]
            if let accessibilityObservation {
                content.append(textContent(
                    "SYNCHRONIZED_AX screen_frame=screen_points; image coordinates=image_pixels. "
                        + "Use snapshot_id with computer_v2_ax or capture_id with computer_v2_click.\n"
                        + accessibilityObservation.text
                ))
            }
            content.append(try imageContent(windowImageAfter))
            return content
        }

        private func computerV2GroundedClickAction(
            _ call: ComputerV2ToolContract.ValidatedCall,
            taskID: AgentTask.ID,
            epoch: UUID
        ) async throws -> [[String: Any]] {
            guard let modelID = modelForTask[taskID],
                  LocalModelCatalog.supportsResidentVisualGrounding(modelID) else {
                throw RuntimeError.serverError(
                    "Resident visual grounding is supported with the 4B and 9B models on this Mac. "
                        + "Use Accessibility, or start a task with one of those models."
                )
            }
            guard visualGroundingResidency.allowsSidecar else {
                throw RuntimeError.serverError(
                    "Visual grounding is unavailable while a 27B or 35B high-memory turn is active."
                )
            }
            _ = try await computerV2BoundApplication(taskID: taskID, epoch: epoch)
            let observed = try computerV2Session(taskID: taskID, epoch: epoch)
            guard observed.browserTab == nil else {
                throw RuntimeError.serverError(
                    "Visual grounding is unavailable for a brokered Chrome tab. "
                        + "Use its semantic browser snapshot and action."
                )
            }
            guard let capture = observed.capture else {
                throw RuntimeError.serverError(
                    "A current screenshot is required before visual grounding."
                )
            }
            guard let suppliedCaptureID = UUID(uuidString: try requiredString(
                "capture_id",
                in: call.arguments
            )), suppliedCaptureID == capture.mapper.captureID else {
                throw RuntimeError.serverError(
                    "The visual-grounding capture is missing or stale. Capture again."
                )
            }
            let target = try requiredString("target", in: call.arguments)
            let request = VisualGroundingRequest(
                id: UUID(),
                png: try pngData(capture.windowImage),
                width: capture.mapper.imageWidth,
                height: capture.mapper.imageHeight,
                target: target
            )
            let decision = try await visualGrounder.ground(request)

            _ = try await computerV2BoundApplication(taskID: taskID, epoch: epoch)
            guard try computerV2Session(taskID: taskID, epoch: epoch)
                .capture?.mapper.captureID == capture.mapper.captureID else {
                throw RuntimeError.serverError(
                    "The screenshot changed during visual grounding. Capture again."
                )
            }
            // The point was inferred from the whole screenshot, so revalidate
            // the whole window before presenting an approval for that decision.
            try await verifyComputerV2WindowUnchanged(capture)
            let synthesizedArguments: [String: Any] = [
                "capture_id": capture.mapper.captureID.uuidString,
                "x": decision.point.x,
                "y": decision.point.y,
            ]
            let synthesized = try ComputerV2ToolContract.validate(
                tool: ComputerV2ToolContract.Tool.click.rawValue,
                arguments: synthesizedArguments
            )
            let evidenceData = try JSONEncoder().encode(decision)
            guard let evidence = try JSONSerialization.jsonObject(
                with: evidenceData
            ) as? [String: Any] else {
                throw RuntimeError.serverError(
                    "The visual-grounding decision could not be encoded."
                )
            }
            let actionContent = try await computerV2PointerAction(
                synthesized,
                taskID: taskID,
                epoch: epoch,
                approvalModelArguments: call.arguments,
                groundingEvidence: evidence,
                approvalSummary: "Locate and click \(target)",
                returnsPostActionObservation: true
            )
            let observationContent = await computerV2PostActionObservation(
                taskID: taskID,
                epoch: epoch
            )
            return actionContent + observationContent
        }

        private func computerV2PostActionObservation(
            taskID: AgentTask.ID,
            epoch: UUID
        ) async -> [[String: Any]] {
            var lastError: Error?
            for delay in [Duration.milliseconds(250), .milliseconds(150)] {
                do {
                    // A click highlight can change the pixels while the strict
                    // synchronized image+AX capture is running. Give it one
                    // bounded settle and one bounded retry; every attempt still
                    // requires a stable, focused, bound window.
                    try await Task.sleep(for: delay)
                    let observation = try await computerV2ReadOnlyPostActionCapture(
                        taskID: taskID,
                        epoch: epoch
                    )
                    return [textContent(
                        "POST_ACTION_OBSERVATION status=available action_dispatched=true "
                            + "captured_after_input=true modality=image+accessibility. "
                            + "Verify the requested visible outcome in the screenshot or Accessibility "
                            + "content; this marker alone is not success. Do not repeat the click."
                    )] + observation
                } catch {
                    lastError = error
                }
            }
            // The mutation already happened. Never turn an observation
            // failure into a failed action that the model might repeat.
            let reason = lastError?.localizedDescription ?? "unknown observation error"
            return [textContent(
                "POST_ACTION_OBSERVATION status=unavailable action_dispatched=true. "
                    + "The click was already dispatched; do not repeat it. "
                    + "Capture one fresh observation to verify the result. Reason: \(reason)"
            )]
        }

        private func computerV2ReadOnlyPostActionCapture(
            taskID: AgentTask.ID,
            epoch: UUID
        ) async throws -> [[String: Any]] {
            let content = try await computerV2Capture(
                arguments: ["include_accessibility": true],
                taskID: taskID,
                epoch: epoch
            )
            // The ordinary capture helper retains an actionable capture ID.
            // This verification image must never re-arm pointer input after a
            // mutation, so clear that capability before returning any content.
            defer {
                if var session = try? computerV2Session(taskID: taskID, epoch: epoch) {
                    session.capture = nil
                    computerV2Sessions[taskID] = session
                }
            }
            guard content.count == 3,
                  let synchronizedText = content[1]["text"] as? String,
                  let newline = synchronizedText.firstIndex(of: "\n"),
                  content[2]["type"] as? String == "inputImage" else {
                throw RuntimeError.serverError(
                    "The read-only post-action observation had an unexpected shape."
                )
            }
            let snapshot = synchronizedText[synchronizedText.index(after: newline)...]
            return [
                textContent(
                    "POST_ACTION_SYNCHRONIZED_AX screen_frame=screen_points. "
                        + "The screenshot is verification-only and has no reusable capture_id. "
                        + "Use its snapshot_id only for a separately approved semantic action.\n"
                        + snapshot
                ),
                content[2],
            ]
        }

        private func computerV2MappedPointerAction(
            _ call: ComputerV2ToolContract.ValidatedCall,
            capture: ComputerV2Capture
        ) throws -> DesktopInputAction {
            guard let captureID = UUID(uuidString: try requiredString(
                "capture_id",
                in: call.arguments
            )) else {
                throw RuntimeError.malformedResponse("A valid capture_id is required.")
            }
            let start = try capture.mapper.screenPoint(
                imageX: requiredFiniteDouble("x", in: call.arguments),
                imageY: requiredFiniteDouble("y", in: call.arguments),
                captureID: captureID,
                maximumAge: 600
            )
            guard ComputerV2TargetContract.contains(
                start,
                in: capture.focusedWindowFrame
            ) else {
                throw RuntimeError.serverError(
                    "The proposed point is outside the captured app window. Observe again."
                )
            }
            if call.tool == .click {
                return .click(start)
            }
            switch call.pointerAction {
            case .move:
                return .move(start)
            case .doubleClick:
                return .doubleClick(start)
            case .rightClick:
                return .rightClick(start)
            case .scroll:
                let deltaX = try optionalInt32("delta_x", in: call.arguments) ?? 0
                let deltaY = try optionalInt32("delta_y", in: call.arguments) ?? 0
                guard deltaX != 0 || deltaY != 0 else {
                    throw RuntimeError.malformedResponse("A non-zero scroll delta is required.")
                }
                return .scroll(point: start, deltaX: deltaX, deltaY: deltaY)
            case nil:
                throw RuntimeError.malformedResponse("Unsupported pointer action.")
            }
        }

        private func verifyComputerV2WindowUnchanged(
            _ capture: ComputerV2Capture,
            targetPoints: [ScreenPoint] = []
        ) async throws {
            let screenshotter = await MainActor.run { WindowScreenshotter() }
            let windows = try await screenshotter.availableWindows()
            guard ComputerV2TargetContract.isSameWindow(
                windows.first(where: { $0.windowID == capture.window.windowID }),
                as: capture.window
            ) else {
                throw RuntimeError.serverError(
                    "The captured app window was replaced or moved. Observe again."
                )
            }
            let image = try await screenshotter.captureWindow(
                windowID: capture.window.windowID,
                scaleFactor: 1
            )
            let baseline: WindowCaptureFingerprint
            let current: WindowCaptureFingerprint
            if targetPoints.isEmpty {
                baseline = capture.fingerprint
                current = try WindowCaptureFingerprint.make(from: image)
            } else {
                let region = try ComputerV2TargetContract.targetPixelRegion(
                    for: targetPoints,
                    windowFrame: capture.window.frame,
                    imageWidth: capture.windowImage.width,
                    imageHeight: capture.windowImage.height
                )
                baseline = try WindowCaptureFingerprint.make(
                    from: capture.windowImage,
                    pixelRegion: region
                )
                current = try WindowCaptureFingerprint.make(
                    from: image,
                    pixelRegion: region
                )
            }
            guard baseline == current else {
                throw RuntimeError.serverError(
                    "The app window target changed after capture. Observe and approve again."
                )
            }
        }

        private func verifyComputerV2DisplayTargetUnchanged(
            _ capture: ComputerV2Capture,
            targetPoints: [ScreenPoint]
        ) async throws {
            let screenshotter = await MainActor.run { DisplayScreenshotter() }
            let displays = try await screenshotter.availableDisplays()
            guard let display = displays.first(where: { $0.displayID == capture.displayID }),
                  display.frame == capture.displayFrame else {
                throw RuntimeError.serverError(
                    "The captured display changed. Capture a fresh screenshot."
                )
            }
            let limits = try DisplayCaptureLimits(
                maximumWidth: 896,
                maximumHeight: 720,
                maximumPixelCount: 600_000
            )
            let currentImage = try await screenshotter.captureDisplay(
                displayID: capture.displayID,
                limits: limits,
                showsCursor: capture.showsCursor
            )
            let region = try ComputerV2TargetContract.targetPixelRegion(
                for: targetPoints,
                windowFrame: capture.displayFrame,
                imageWidth: capture.displayImage.width,
                imageHeight: capture.displayImage.height,
                radius: 64
            )
            let baseline = try WindowCaptureFingerprint.make(
                from: capture.displayImage,
                pixelRegion: region
            )
            let current = try WindowCaptureFingerprint.make(
                from: currentImage,
                pixelRegion: region
            )
            guard baseline == current else {
                throw RuntimeError.serverError(
                    "The visible target changed after capture. Capture a fresh screenshot."
                )
            }
        }

        private func computerV2PointerAction(
            _ call: ComputerV2ToolContract.ValidatedCall,
            taskID: AgentTask.ID,
            epoch: UUID,
            approvalModelArguments: [String: Any]? = nil,
            groundingEvidence: [String: Any]? = nil,
            approvalSummary: String? = nil,
            returnsPostActionObservation: Bool = false
        ) async throws -> [[String: Any]] {
            let application = try await computerV2BoundApplication(
                taskID: taskID,
                epoch: epoch
            )
            guard try computerV2Session(
                taskID: taskID,
                epoch: epoch
            ).browserTab == nil else {
                throw RuntimeError.serverError(
                    "Coordinate and keyboard input are unavailable for a brokered Chrome tab. "
                        + "Use a semantic browser snapshot and action."
                )
            }
            guard let capture = try computerV2Session(
                taskID: taskID,
                epoch: epoch
            ).capture else {
                throw RuntimeError.serverError(
                    "A current screenshot is required before image-coordinate input."
                )
            }
            let action = try computerV2MappedPointerAction(call, capture: capture)
            var approvalDetails: [String: Any] = [
                "model_arguments": approvalModelArguments ?? call.arguments,
                "resolved_target": [
                    "bundle_id": application.bundleIdentifier,
                    "process_id": application.processIdentifier,
                ],
                "resolved_action": action.summary,
            ]
            if let groundingEvidence {
                approvalDetails["visual_grounding"] = groundingEvidence
            }
            let approved = await requestComputerUseApproval(
                taskID: taskID,
                title: "Allow computer input?",
                summary: approvalSummary ?? action.summary,
                details: prettyJSON(approvalDetails)
            )
            guard approved else {
                throw RuntimeError.serverError("The user declined computer input.")
            }
            _ = try await computerV2BoundApplication(taskID: taskID, epoch: epoch)
            guard try computerV2Session(taskID: taskID, epoch: epoch)
                .capture?.mapper.captureID == capture.mapper.captureID else {
                throw RuntimeError.serverError("The approved screenshot is no longer current.")
            }
            // Repeat the age/ID check after the user approval may have waited.
            _ = try computerV2MappedPointerAction(call, capture: capture)
            let controller = await MainActor.run { ComputerInputController() }
            let activated = try await controller.activateApplication(
                processIdentifier: application.processIdentifier
            )
            guard activated.processIdentifier == application.processIdentifier,
                  activated.bundleIdentifier == application.bundleIdentifier else {
                throw RuntimeError.serverError("The approved application target changed.")
            }
            let focused = try await MainActor.run {
                try FocusedWindowReader().focusedWindow()
            }
            _ = try await computerV2BoundApplication(taskID: taskID, epoch: epoch)
            guard ComputerV2TargetContract.isSameFocusedWindow(
                focused,
                as: capture.focusedWindowFrame,
                for: application
            ) else {
                throw RuntimeError.serverError(
                    "The app window moved or changed after capture. Observe again."
                )
            }
            try await verifyComputerV2WindowUnchanged(
                capture,
                targetPoints: ComputerV2FreshnessPolicy.windowFingerprintTargets(
                    action.pointerTargets,
                    usesVisualGrounding: groundingEvidence != nil
                )
            )
            try await verifyComputerV2DisplayTargetUnchanged(
                capture,
                targetPoints: action.pointerTargets
            )
            guard try await capture.focusedWindowIdentity.isStillFocused() else {
                throw RuntimeError.serverError(
                    "The captured window lost focus before input. Observe again."
                )
            }
            _ = try await computerV2BoundApplication(taskID: taskID, epoch: epoch)
            try clearComputerV2Observation(taskID: taskID, epoch: epoch)
            try await Self.performComputerV2Input(
                action,
                using: controller,
                application: application,
                expectedWindowFrame: capture.focusedWindowFrame,
                expectedWindowIdentity: capture.focusedWindowIdentity,
                expectedWindowID: capture.window.windowID
            )
            if returnsPostActionObservation {
                return [textContent(
                    "Requested \(action.name). The click was dispatched; "
                        + "a fresh post-action observation follows. Do not repeat the action."
                )]
            }
            return [textContent(
                "Requested \(action.name). Capture a fresh screenshot or Accessibility snapshot to verify the result."
            )]
        }

        private func computerV2KeyboardAction(
            _ call: ComputerV2ToolContract.ValidatedCall,
            taskID: AgentTask.ID,
            epoch: UUID
        ) async throws -> [[String: Any]] {
            let application = try await computerV2BoundApplication(
                taskID: taskID,
                epoch: epoch
            )
            guard try computerV2Session(
                taskID: taskID,
                epoch: epoch
            ).browserTab == nil else {
                throw RuntimeError.serverError(
                    "Coordinate and keyboard input are unavailable for a brokered Chrome tab. "
                        + "Use a semantic browser snapshot and action."
                )
            }
            let observation = try computerV2Session(taskID: taskID, epoch: epoch)
            guard observation.accessibility != nil || observation.capture != nil else {
                throw RuntimeError.serverError(
                    "Observe the bound app with a snapshot or screenshot before keyboard input."
                )
            }
            var input = call.arguments
            input["action"] = call.tool == .keypress ? "keypress" : "type"
            let action = try parseDesktopInputAction(input)
            let approved = await requestComputerUseApproval(
                taskID: taskID,
                title: "Allow computer input?",
                summary: action.summary,
                details: computerV2ApprovalDetails(
                    arguments: call.arguments,
                    application: application
                )
            )
            guard approved else {
                throw RuntimeError.serverError("The user declined computer input.")
            }
            _ = try await computerV2BoundApplication(taskID: taskID, epoch: epoch)
            let current = try computerV2Session(taskID: taskID, epoch: epoch)
            guard current.accessibility?.snapshot.id == observation.accessibility?.snapshot.id,
                  current.capture?.mapper.captureID == observation.capture?.mapper.captureID else {
                throw RuntimeError.serverError("The approved observation is no longer current.")
            }
            if let capture = observation.capture {
                _ = try capture.mapper.screenPoint(
                    imageX: 0,
                    imageY: 0,
                    captureID: capture.mapper.captureID,
                    maximumAge: 600
                )
            }
            let controller = await MainActor.run { ComputerInputController() }
            let activated = try await controller.activateApplication(
                processIdentifier: application.processIdentifier
            )
            guard activated.processIdentifier == application.processIdentifier,
                  activated.bundleIdentifier == application.bundleIdentifier else {
                throw RuntimeError.serverError("The approved application target changed.")
            }
            if let capture = observation.capture {
                let focused = try await MainActor.run {
                    try FocusedWindowReader().focusedWindow()
                }
                guard ComputerV2TargetContract.isSameFocusedWindow(
                    focused,
                    as: capture.focusedWindowFrame,
                    for: application
                ) else {
                    throw RuntimeError.serverError(
                        "The app window moved or changed after capture. Observe again."
                    )
                }
                try await verifyComputerV2WindowUnchanged(capture)
            } else if let active = observation.accessibility {
                try await prepareAccessibilityMutation(
                    active,
                    processIdentifier: application.processIdentifier
                )
            }
            guard let windowIdentity = observation.capture?.focusedWindowIdentity
                ?? observation.accessibilityWindowIdentity,
                  try await windowIdentity.isStillFocused() else {
                throw RuntimeError.serverError(
                    "The inspected window changed before keyboard input. Observe again."
                )
            }
            _ = try await computerV2BoundApplication(taskID: taskID, epoch: epoch)
            try clearComputerV2Observation(taskID: taskID, epoch: epoch)
            try await Self.performComputerV2Input(
                action,
                using: controller,
                application: application,
                expectedWindowFrame: observation.capture?.focusedWindowFrame,
                expectedWindowIdentity: windowIdentity,
                expectedWindowID: nil
            )
            return [textContent(
                "Requested \(action.name). Observe the app again to verify the result."
            )]
        }

        /// The final focus check and each synchronous input primitive execute
        /// in one MainActor turn. This closes the async gap between screenshot
        /// revalidation and posting the event, including a different task or
        /// the user taking focus while an approval was on screen.
        @MainActor
        private static func performComputerV2Input(
            _ action: DesktopInputAction,
            using controller: ComputerInputController,
            application: ActivatedApplication,
            expectedWindowFrame: WindowFrame?,
            expectedWindowIdentity: FocusedWindowIdentity,
            expectedWindowID: UInt32?
        ) async throws {
            let focused = try FocusedWindowReader().focusedWindow()
            guard let focused,
                  focused.processIdentifier == application.processIdentifier,
                  focused.bundleIdentifier == application.bundleIdentifier
            else {
                throw RuntimeError.serverError(
                    "The approved app lost focus before input. Observe again."
                )
            }
            if let expectedWindowFrame {
                guard ComputerV2TargetContract.isSameFocusedWindow(
                    focused,
                    as: expectedWindowFrame,
                    for: application
                ) else {
                    throw RuntimeError.serverError(
                        "The approved window changed before input. Observe again."
                    )
                }
            }
            guard try expectedWindowIdentity.isStillFocused() else {
                throw RuntimeError.serverError(
                    "The approved window lost focus before input. Observe again."
                )
            }
            if !action.pointerTargets.isEmpty {
                guard let expectedWindowID else {
                    throw RuntimeError.serverError("The pointer target has no verified window.")
                }
                try WindowHitTestVerifier().verifyUnobstructed(
                    expectedWindowID: expectedWindowID,
                    points: action.pointerTargets
                )
            }

            switch action {
            case .move(let point):
                try controller.moveMouse(to: point)
            case .click(let point):
                try controller.click(at: point)
            case .doubleClick(let point):
                try controller.doubleClick(at: point)
            case .rightClick(let point):
                try controller.rightClick(at: point)
            case .scroll(let point, let deltaX, let deltaY):
                try controller.scroll(at: point, deltaX: deltaX, deltaY: deltaY)
            case .drag:
                // Legacy persisted `computer` calls still use the separate
                // `perform` path. V2 must not post a delayed drag sequence.
                throw RuntimeError.serverError("Drag is unavailable in computer V2.")
            case .keypress(let chord, _):
                guard try expectedWindowIdentity.isSameFocusedUIElement() else {
                    throw RuntimeError.serverError(
                        "The focused control changed before keyboard input. Observe again."
                    )
                }
                try controller.pressKeyChord(chord)
            case .type(let text):
                guard try expectedWindowIdentity.isSameFocusedUIElement() else {
                    throw RuntimeError.serverError(
                        "The focused control changed before keyboard input. Observe again."
                    )
                }
                try controller.enterText(text)
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
                if let taskID {
                    computerApprovalTask[request.id] = taskID
                }
                events.yield(.approvalRequested(request))
            }
        }

        private func parseDesktopInputAction(
            _ arguments: [String: Any]
        ) throws -> DesktopInputAction {
            let name = try requiredString("action", in: arguments)
            switch name {
            case "move":
                return .move(try requiredPoint(arguments))
            case "click":
                return .click(try requiredPoint(arguments))
            case "double_click":
                return .doubleClick(try requiredPoint(arguments))
            case "right_click":
                return .rightClick(try requiredPoint(arguments))
            case "scroll":
                let point = try requiredPoint(arguments)
                let deltaX = try optionalInt32("delta_x", in: arguments) ?? 0
                let deltaY = try optionalInt32("delta_y", in: arguments) ?? 0
                guard deltaX != 0 || deltaY != 0 else {
                    throw RuntimeError.malformedResponse("scroll requires a non-zero delta_x or delta_y")
                }
                return .scroll(point: point, deltaX: deltaX, deltaY: deltaY)
            case "drag":
                let start = try requiredPoint(arguments)
                let end = ScreenPoint(
                    x: try requiredFiniteDouble("end_x", in: arguments),
                    y: try requiredFiniteDouble("end_y", in: arguments)
                )
                let duration = try optionalFiniteDouble("duration", in: arguments) ?? 0.25
                guard (0 ... 30).contains(duration) else {
                    throw RuntimeError.malformedResponse("duration must be between 0 and 30 seconds")
                }
                return .drag(start: start, end: end, duration: duration)
            case "keypress":
                let keyName = try requiredString("key", in: arguments)
                let keyCode = try keyCode(named: keyName)
                guard let rawModifiers = ComputerToolArgumentContract.optionalStringArray(
                    arguments["modifiers"]
                ) else {
                    throw RuntimeError.malformedResponse("modifiers must be an array of strings")
                }
                guard rawModifiers.count <= KeyboardModifier.allCases.count else {
                    throw RuntimeError.malformedResponse("Too many keyboard modifiers were supplied.")
                }
                var modifiers = Set<KeyboardModifier>()
                for rawModifier in rawModifiers {
                    guard let modifier = KeyboardModifier(rawValue: rawModifier) else {
                        throw RuntimeError.malformedResponse("Unsupported keyboard modifier: \(rawModifier)")
                    }
                    modifiers.insert(modifier)
                }
                return .keypress(
                    KeyboardChord(keyCode: keyCode, modifiers: modifiers),
                    keyName: keyName
                )
            case "type":
                let text = try requiredString("text", in: arguments)
                guard text.count <= 4_096 else {
                    throw RuntimeError.malformedResponse("text may not exceed 4096 characters")
                }
                return .type(text)
            default:
                throw RuntimeError.malformedResponse("Unsupported desktop input action: \(name)")
            }
        }

        private func perform(
            _ action: DesktopInputAction,
            using controller: ComputerInputController
        ) async throws {
            switch action {
            case .move(let point):
                try await controller.moveMouse(to: point)
            case .click(let point):
                try await controller.click(at: point)
            case .doubleClick(let point):
                try await controller.doubleClick(at: point)
            case .rightClick(let point):
                try await controller.rightClick(at: point)
            case .scroll(let point, let deltaX, let deltaY):
                try await controller.scroll(at: point, deltaX: deltaX, deltaY: deltaY)
            case .drag(let start, let end, let duration):
                try await controller.drag(from: start, to: end, duration: duration)
            case .keypress(let chord, _):
                try await controller.pressKeyChord(chord)
            case .type(let text):
                try await controller.enterText(text)
            }
        }

        private func requiredPoint(_ arguments: [String: Any]) throws -> ScreenPoint {
            ScreenPoint(
                x: try requiredFiniteDouble("x", in: arguments),
                y: try requiredFiniteDouble("y", in: arguments)
            )
        }

        private func requiredFiniteDouble(
            _ key: String,
            in arguments: [String: Any]
        ) throws -> Double {
            guard let value = ComputerToolArgumentContract.finiteDouble(arguments[key]) else {
                throw RuntimeError.malformedResponse("A finite numeric \(key) is required.")
            }
            return value
        }

        private func optionalFiniteDouble(
            _ key: String,
            in arguments: [String: Any]
        ) throws -> Double? {
            guard let rawValue = arguments[key] else { return nil }
            guard let value = ComputerToolArgumentContract.finiteDouble(rawValue) else {
                throw RuntimeError.malformedResponse("\(key) must be a finite number.")
            }
            return value
        }

        private func optionalInt32(
            _ key: String,
            in arguments: [String: Any]
        ) throws -> Int32? {
            guard let rawValue = arguments[key] else { return nil }
            guard let integer = ComputerToolArgumentContract.exactInt64(rawValue),
                  let value = Int32(exactly: integer),
                  (-10_000 ... 10_000).contains(value)
            else {
                throw RuntimeError.malformedResponse("\(key) must be an integer from -10000 through 10000.")
            }
            return value
        }

        private func optionalUInt32(
            _ key: String,
            in arguments: [String: Any]
        ) throws -> UInt32? {
            guard let rawValue = arguments[key] else { return nil }
            guard let integer = ComputerToolArgumentContract.exactInt64(rawValue),
                  integer > 0,
                  let value = UInt32(exactly: integer)
            else {
                throw RuntimeError.malformedResponse("\(key) must be a positive 32-bit integer.")
            }
            return value
        }

        private func optionalOpenURL(_ rawValue: Any?) throws -> URL? {
            guard let rawValue else { return nil }
            guard let value = rawValue as? String,
                  !value.isEmpty,
                  value.count <= 8_192,
                  let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "file"].contains(scheme)
            else {
                throw RuntimeError.malformedResponse("url must be a valid http, https, or file URL")
            }
            return url
        }

        private func keyCode(named rawName: String) throws -> UInt16 {
            let name = rawName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            let keyCodes: [String: UInt16] = [
                "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
                "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
                "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
                "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
                "equals": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29,
                "right_bracket": 30, "o": 31, "u": 32, "left_bracket": 33,
                "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37,
                "j": 38, "quote": 39, "k": 40, "semicolon": 41,
                "backslash": 42, "comma": 43, "slash": 44, "n": 45,
                "m": 46, "period": 47, "tab": 48, "space": 49,
                "grave": 50, "delete": 51, "backspace": 51, "escape": 53,
                "esc": 53, "f5": 96, "f6": 97, "f7": 98, "f3": 99,
                "f8": 100, "f9": 101, "f11": 103, "f10": 109, "f12": 111,
                "home": 115, "page_up": 116, "forward_delete": 117, "f4": 118,
                "end": 119, "f2": 120, "page_down": 121, "f1": 122,
                "left": 123, "right": 124, "down": 125, "up": 126,
            ]
            guard let keyCode = keyCodes[name] else {
                throw RuntimeError.malformedResponse("Unsupported key name: \(rawName)")
            }
            return keyCode
        }

        private func requiredProcessID(_ arguments: [String: Any]) throws -> Int32 {
            try ComputerToolArgumentContract.requiredProcessID(arguments)
        }

        private func requiredIndex(_ arguments: [String: Any]) throws -> Int {
            guard let integer = ComputerToolArgumentContract.exactInt64(arguments["element_index"]),
                  integer >= 0,
                  let value = Int(exactly: integer)
            else {
                throw RuntimeError.malformedResponse("A non-negative element_index is required.")
            }
            return value
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

        private func prepareAccessibilityMutation(
            _ active: ActiveAccessibilitySession,
            processIdentifier: Int32
        ) async throws {
            // The native approval overlay activates LocalCodex. Restore the
            // exact inspected process and window before using the retained AX
            // handle. Requiring a short continuous focused interval lets the
            // approval click, SwiftUI teardown, and AppKit activation handoff
            // quiesce before Chromium receives the one approved action, while
            // still preserving the originally inspected snapshot target.
            let controller = await MainActor.run { ComputerInputController() }
            _ = try await controller.activateApplication(
                processIdentifier: processIdentifier
            )
            let initialFocusState = try active.session.focusState(in: active.snapshot)
            guard initialFocusState != .notWindow else {
                return
            }
            if initialFocusState != .focused {
                _ = try active.session.raiseSnapshotWindow(in: active.snapshot)
            }

            var consecutiveFocusedSamples = 0
            for _ in 0 ..< 80 {
                switch try active.session.focusState(in: active.snapshot) {
                case .focused:
                    consecutiveFocusedSamples += 1
                    if consecutiveFocusedSamples == 12 {
                        return
                    }
                case .notWindow:
                    return
                case .applicationNotFocused, .windowNotFocused:
                    consecutiveFocusedSamples = 0
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw RuntimeError.serverError(
                "The inspected Accessibility window did not become focused. Capture a fresh snapshot and try again."
            )
        }

        private func textContent(_ text: String) -> [String: Any] {
            ["type": "inputText", "text": text]
        }

        private func imageContent(_ image: CGImage) throws -> [String: Any] {
            let png = try pngData(image)
            return [
                "type": "inputImage",
                "imageUrl": "data:image/png;base64,\(png.base64EncodedString())",
            ]
        }

        private func pngData(_ image: CGImage) throws -> Data {
            guard let png = NSBitmapImageRep(cgImage: image).representation(
                using: .png,
                properties: [:]
            ) else {
                throw RuntimeError.serverError("Could not encode the screenshot as PNG.")
            }
            return png
        }

        private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }

        private func request(method: String, params: [String: Any]) async throws -> Data {
            guard !isShuttingDown else { throw RuntimeError.serverStopped }
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
            recordProtocolBytes(data, direction: "client_to_server")
        }

        private func startProtocolTrace(atPath path: String) throws {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = FileManager.default.createFile(atPath: path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            protocolTraceHandle = handle
            protocolTraceSequence = 0
        }

        private func recordProtocolBytes(_ data: Data, direction: String) {
            guard let protocolTraceHandle else { return }
            protocolTraceSequence += 1
            let record: [String: Any] = [
                "sequence": protocolTraceSequence,
                "direction": direction,
                "wireBase64": data.base64EncodedString(),
            ]
            guard var encoded = try? JSONSerialization.data(
                withJSONObject: record,
                options: [.sortedKeys]
            ) else { return }
            encoded.append(0x0A)
            try? protocolTraceHandle.write(contentsOf: encoded)
            try? protocolTraceHandle.synchronize()
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

        private func serverEnded(generation: UUID) {
            guard generation == serverGeneration, process != nil else { return }
            serverFailed(RuntimeError.serverStopped)
        }

        private func serverFailed(_ error: Error) {
            serverGeneration = UUID()
            let dynamicTasks = dynamicToolTasks.values.map(\.task)
            dynamicToolTasks.removeAll()
            dynamicTasks.forEach { $0.cancel() }
            for taskID in Array(computerV2Sessions.keys) {
                discardComputerV2Session(taskID: taskID)
            }
            if let child = process {
                retiringChildren[child.processIdentifier] = child
                Task {
                    let stopped = await child.stop()
                    childCleanupIssues.append(contentsOf: stopped.issues)
                    if stopped.succeeded {
                        retiringChildren.removeValue(forKey: child.processIdentifier)
                    }
                }
            }
            isReady = false
            outputHandle?.readabilityHandler = nil
            errorHandle?.readabilityHandler = nil
            try? outputHandle?.close()
            try? errorHandle?.close()
            try? input?.close()
            outputHandle = nil
            errorHandle = nil
            try? protocolTraceHandle?.close()
            protocolTraceHandle = nil
            outputBuffer.removeAll(keepingCapacity: false)
            process = nil
            input = nil
            let computerUseContinuations = pendingComputerUseApprovals.values
            let unresolvedApprovalIDs = Array(pendingComputerUseApprovals.keys)
                + Array(pendingServerApprovals.keys)
            pendingComputerUseApprovals.removeAll()
            computerApprovalTask.removeAll()
            pendingServerApprovals.removeAll()
            accessibilitySessions.removeAll()
            computerV2Sessions.removeAll()
            visualGroundingResidency.removeAll()
            // A restarted App Server has no loaded thread state. Keep task-to-
            // thread IDs for cold resume, but reapply the selected model's
            // context configuration before the next turn.
            contextForLoadedThread.removeAll()
            turnForTask.removeAll()
            computerV2InFlight.removeAll()
            computerGlobalInFlight = nil
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
            if !isShuttingDown {
                events.yield(.connectionChanged(.failed(message: error.localizedDescription)))
            }
        }
    }
}

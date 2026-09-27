import Foundation

enum LocalInferenceBackend: String, Equatable, Sendable {
    case headlessMLX
    case external

    var displayName: String { self == .headlessMLX ? "Headless MLX" : "External local server" }

    func launchEnvironment(_ inherited: [String: String]) -> [String: String] {
        guard self == .headlessMLX else { return inherited }
        var result = inherited
        result["CODEX_OSS_BASE_URL"] = "http://127.0.0.1:1237/v1"
        result.removeValue(forKey: "CODEX_OSS_PORT")
        return result
    }
}

struct HeadlessMLXConfiguration: Sendable {
    let python: URL
    let script: URL
    let modelRoot: URL
    var fallbackModelRoot: URL? = nil
    var startupTimeout: Duration = .seconds(60)
    let healthURL = URL(string: "http://127.0.0.1:1237/health")!

    static func local() throws -> Self {
        let files = FileManager.default
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false)
        #if SWIFT_PACKAGE
        let bundles = [Bundle.module, Bundle.main]
        #else
        let bundles = [Bundle.main]
        #endif
        guard let resource = bundles.lazy.compactMap({ $0.url(forResource: "MLXServer", withExtension: nil) }).first else {
            throw HeadlessMLXServer.Failure.unavailable("The bundled MLX server is missing.")
        }
        return localPaths(support: support, home: files.homeDirectoryForCurrentUser,
                          script: resource.appendingPathComponent("server.py"),
                          isExecutable: files.isExecutableFile(atPath:))
    }

    static func localPaths(support: URL, home: URL, script: URL,
                           isExecutable: (String) -> Bool) -> Self {
        let ownedPython = support.appendingPathComponent("LocalCodex/MLX/venv/bin/python")
        let legacyPython = support.appendingPathComponent("LocalCodex/VisualGrounding/venv/bin/python")
        // Existing installations keep working without copying weights or
        // changing the visual-grounding environment. New installs are independent.
        return Self(python: isExecutable(ownedPython.path) || !isExecutable(legacyPython.path)
                    ? ownedPython : legacyPython,
                    script: script,
                    modelRoot: support.appendingPathComponent("LocalCodex/MLX/models"),
                    fallbackModelRoot: home.appendingPathComponent(".lmstudio/models"))
    }

    var arguments: [String] {
        var result = ["-B", "-u", script.path, "--port", "1237", "--model-root", modelRoot.path]
        if let fallbackModelRoot { result += ["--fallback-model-root", fallbackModelRoot.path] }
        return result + ["--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
    }

    func environment(instance: String) -> [String: String] {
        // Do not forward API keys, proxy settings, or arbitrary Python startup hooks.
        ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
         "PATH": "\(python.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin",
         "PYTHONNOUSERSITE": "1", "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1",
         "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
         "TOKENIZERS_PARALLELISM": "false", "HEYDASH_MLX_INSTANCE": instance]
    }
}

protocol HeadlessMLXProcess: Sendable {
    var isRunning: Bool { get }
    func stop() async -> OwnedChildProcess.StopResult
}

extension OwnedChildProcess: HeadlessMLXProcess {}

/// Native work ownership, not model-authored state. Every producer that could
/// still be using inference must be idle before replacing its process.
struct HeadlessMLXWorkState: Equatable, Sendable {
    var activeOrStartingTurn = false
    var competingSubmission = false
    var compaction = false
    var toolInFlight = false
    var selectionInProgress = false

    var isIdle: Bool {
        !activeOrStartingTurn && !competingSubmission && !compaction && !toolInFlight && !selectionInProgress
    }
}

/// One owned, loopback-only inference service. Readiness is not model loading;
/// weights stay lazy. An unrelated listener is never adopted or terminated.
actor HeadlessMLXServer {
    enum Failure: LocalizedError, Equatable {
        case unavailable(String)
        case portOccupied
        case timedOut
        case exited
        case stopped
        case unsupportedModel
        case busy
        case cleanup([String])

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): message
            case .portOccupied: "Port 1237 is already occupied or its MLX ownership could not be verified. No unrelated process was stopped."
            case .timedOut: "The owned MLX server did not become ready within its startup deadline. No prompt was sent."
            case .exited: "The owned MLX server exited. Check the local Python environment and bundled server. No prompt was sent."
            case .stopped: "The owned MLX server is stopped."
            case .unsupportedModel: "This saved model is not supported by Mactopus's headless MLX backend. Select Qwen 4B or 9B, or explicitly use an external local server. No model was switched and no prompt was sent."
            case .busy: "The owned local model is busy with another turn, submission, or context operation. Wait for it to finish before switching models or sending another task. No model was switched and no prompt was sent."
            case .cleanup(let issues): "MLX server cleanup could not be verified: \(issues.joined(separator: "; "))"
            }
        }
    }

    struct Health: Equatable, Sendable {
        let status: Int
        let body: Data
    }

    struct Operations: Sendable {
        let launch: @Sendable (HeadlessMLXConfiguration, String) throws -> any HeadlessMLXProcess
        let health: @Sendable (URL) async throws -> Health?

        static let live = Self(launch: { configuration, instance in
            guard FileManager.default.isExecutableFile(atPath: configuration.python.path),
                  FileManager.default.isReadableFile(atPath: configuration.script.path) else {
                throw Failure.unavailable("The local MLX Python environment or bundled server is unavailable. No installation or download was attempted.")
            }
            return try OwnedChildProcess(executableURL: configuration.python, arguments: configuration.arguments,
                                         environment: configuration.environment(instance: instance))
        }, health: { url in try await HeadlessMLXServer.readHealth(url) })
    }

    private let configuration: HeadlessMLXConfiguration
    private let operations: Operations
    private var instance = UUID().uuidString.lowercased()
    private var child: (any HeadlessMLXProcess)?
    private var startTask: Task<Void, Error>?
    private var stopped = false
    private var cleanupIssues: [String] = []
    private var selectedModelID: String?
    private var changingModel = false

    init(configuration: HeadlessMLXConfiguration, operations: Operations = .live) {
        self.configuration = configuration
        self.operations = operations
    }

    func start() async throws {
        guard !changingModel else { throw Failure.busy }
        try await startGeneration()
    }

    private func startGeneration() async throws {
        guard !stopped else { throw Failure.stopped }
        let task: Task<Void, Error>
        if let existing = startTask { task = existing }
        else {
            task = Task { try await self.startOnce() }
            startTask = task
        }
        try await withTaskCancellationHandler(operation: {
            try await task.value
            try Task.checkCancellation()
        }, onCancel: { task.cancel() })
        // A completed startup task is not a lifetime proof. Never report ready
        // after a later child exit, or silently adopt a replacement listener.
        guard !stopped else { throw Failure.stopped }
        guard child?.isRunning == true else {
            let issues = await shutdown()
            if !issues.isEmpty { throw Failure.cleanup(issues) }
            throw Failure.exited
        }
    }

    /// Upstream 0.7.1 can retain old weights while loading a replacement model.
    /// Model changes therefore get an entirely new process, never /unload or an
    /// in-process load. The App Server and saved conversations are unaffected.
    func prepare(modelID: String, activity: HeadlessMLXWorkState) async throws {
        guard LocalModelCatalog.supportsHeadlessMLX(modelID) else { throw Failure.unsupportedModel }
        guard !changingModel, activity.isIdle else { throw Failure.busy }
        changingModel = true
        defer { changingModel = false }
        try await startGeneration()
        try Task.checkCancellation()
        if selectedModelID == modelID { return }
        if selectedModelID == nil {
            selectedModelID = modelID
            return
        }
        // A terminal App Server event may slightly precede HTTP worker cleanup.
        // Require the exact owner's idle response as a second independent gate.
        guard let health = try await operations.health(configuration.healthURL),
              Self.ownsHealthyResponse(health, instance: instance),
              let object = try? JSONSerialization.jsonObject(with: health.body) as? [String: Any],
              object["busy"] as? Bool == false else { throw Failure.busy }
        try Task.checkCancellation()
        guard !stopped, let previous = child, previous.isRunning else { throw Failure.exited }
        let result = await previous.stop()
        cleanupIssues.append(contentsOf: result.issues)
        guard result.succeeded else {
            stopped = true
            throw Failure.cleanup(result.issues)
        }
        child = nil
        startTask = nil
        selectedModelID = nil
        // Do not spawn after cancellation/shutdown or while a foreign listener
        // has taken the port. startGeneration checks listener absence itself.
        try Task.checkCancellation()
        guard !stopped else { throw Failure.stopped }
        instance = UUID().uuidString.lowercased()
        try await startGeneration()
        try Task.checkCancellation()
        guard !stopped else { throw Failure.stopped }
        selectedModelID = modelID
    }

    private func startOnce() async throws {
        do {
            try Task.checkCancellation()
            guard try await operations.health(configuration.healthURL) == nil else { throw Failure.portOccupied }
            try Task.checkCancellation()
            guard !stopped else { throw Failure.stopped }
            child = try operations.launch(configuration, instance)
            let deadline = ContinuousClock.now + configuration.startupTimeout
            repeat {
                try Task.checkCancellation()
                guard !stopped else { throw Failure.stopped }
                guard child?.isRunning == true else { throw Failure.exited }
                if let health = try await operations.health(configuration.healthURL) {
                    guard Self.ownsHealthyResponse(health, instance: instance), child?.isRunning == true else {
                        throw Failure.portOccupied
                    }
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < deadline
            throw Failure.timedOut
        } catch {
            stopped = true
            if let child {
                let result = await child.stop()
                cleanupIssues.append(contentsOf: result.issues)
                if !result.succeeded { throw Failure.cleanup(result.issues) }
                self.child = nil
            }
            throw error
        }
    }

    func shutdown() async -> [String] {
        stopped = true
        startTask?.cancel()
        _ = await startTask?.result
        if let child {
            let result = await child.stop()
            cleanupIssues.append(contentsOf: result.issues)
            if result.succeeded { self.child = nil }
        }
        return Array(Set(cleanupIssues)).sorted()
    }

    static func ownsHealthyResponse(_ health: Health, instance: String) -> Bool {
        guard health.status == 200, health.body.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: health.body) as? [String: Any],
              let identity = object["heydash_instance"] as? String,
              let actual = UUID(uuidString: identity), actual == UUID(uuidString: instance),
              object["status"] as? String == "healthy" else { return false }
        return true
    }

    private static func readHealth(_ url: URL) async throws -> Health? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 1
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let response = response as? HTTPURLResponse else { throw Failure.portOccupied }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 4096 else { throw Failure.portOccupied }
                data.append(byte)
            }
            return Health(status: response.statusCode, body: data)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return nil
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Failure.portOccupied
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

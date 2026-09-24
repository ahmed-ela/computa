import Darwin
import Foundation

struct VisualGroundingRequest: Sendable {
    let id: UUID
    let png: Data
    let width: Int
    let height: Int
    let target: String
}

struct VisualGroundingPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct VisualGroundingModelPoints: Codable, Equatable, Sendable {
    let goClick: VisualGroundingPoint?
    let guiOwl2B: VisualGroundingPoint?
    let showUI: VisualGroundingPoint?

    enum CodingKeys: String, CodingKey {
        case goClick = "goclick"
        case guiOwl2B = "gui_owl_2b"
        case showUI = "showui"
    }
}

struct VisualGroundingModelLatency: Codable, Equatable, Sendable {
    let goClick: Double
    let guiOwl2B: Double
    let showUI: Double?

    enum CodingKeys: String, CodingKey {
        case goClick = "goclick"
        case guiOwl2B = "gui_owl_2b"
        case showUI = "showui"
    }
}

struct VisualGroundingDecision: Codable, Equatable, Sendable {
    static let methodVersion = "goclick-guiowl-showui-agreement-v2"
    static let agreementThreshold = 0.03

    let point: VisualGroundingPoint
    let methodVersion: String
    let usedShowUI: Bool
    let selectedPair: [String]
    let agreementThresholdNormalizedDiagonal: Double
    let initialDistanceNormalizedDiagonal: Double?
    let selectedDistanceNormalizedDiagonal: Double
    let modelPoints: VisualGroundingModelPoints
    let modelLatencyMS: VisualGroundingModelLatency
    let latencyMS: Double
    let imageWidth: Int
    let imageHeight: Int

    enum CodingKeys: String, CodingKey {
        case point
        case methodVersion = "method_version"
        case usedShowUI = "used_showui"
        case selectedPair = "selected_pair"
        case agreementThresholdNormalizedDiagonal = "agreement_threshold_normalized_diagonal"
        case initialDistanceNormalizedDiagonal = "initial_distance_normalized_diagonal"
        case selectedDistanceNormalizedDiagonal = "selected_distance_normalized_diagonal"
        case modelPoints = "model_points"
        case modelLatencyMS = "model_latency_ms"
        case latencyMS = "latency_ms"
        case imageWidth = "image_width"
        case imageHeight = "image_height"
    }

    func validated(for request: VisualGroundingRequest) throws -> Self {
        guard methodVersion == Self.methodVersion else {
            throw VisualGroundingError.protocolViolation("unexpected method version")
        }
        guard imageWidth == request.width, imageHeight == request.height else {
            throw VisualGroundingError.protocolViolation("worker image dimensions changed")
        }
        guard agreementThresholdNormalizedDiagonal == Self.agreementThreshold else {
            throw VisualGroundingError.protocolViolation("unexpected agreement threshold")
        }
        try Self.validate(point, width: request.width, height: request.height)
        for candidate in [modelPoints.goClick, modelPoints.guiOwl2B, modelPoints.showUI].compactMap({ $0 }) {
            try Self.validate(candidate, width: request.width, height: request.height)
        }
        if usedShowUI != (modelPoints.showUI != nil)
            || usedShowUI != (modelLatencyMS.showUI != nil) {
            throw VisualGroundingError.protocolViolation("ShowUI routing evidence is inconsistent")
        }
        let finiteNonnegative = [
            initialDistanceNormalizedDiagonal,
            selectedDistanceNormalizedDiagonal,
            modelLatencyMS.goClick,
            modelLatencyMS.guiOwl2B,
            modelLatencyMS.showUI,
            latencyMS,
        ].compactMap { $0 }
        guard finiteNonnegative.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw VisualGroundingError.protocolViolation("nonfinite or negative grounding metric")
        }
        let named = [
            ("goclick", modelPoints.goClick),
            ("gui_owl_2b", modelPoints.guiOwl2B),
            ("showui", modelPoints.showUI),
        ]
        let valid = named.compactMap { name, candidate in
            candidate.map { (name, $0) }
        }
        guard valid.count >= 2 else {
            throw VisualGroundingError.protocolViolation("fewer than two valid model points")
        }
        let diagonal = hypot(Double(request.width), Double(request.height))
        let initialDistance = Self.distance(modelPoints.goClick, modelPoints.guiOwl2B)
        let expectedShowUI = initialDistance.map {
            $0 > Self.agreementThreshold * diagonal
        } ?? true
        guard usedShowUI == expectedShowUI,
              Self.approximatelyEqual(
                  initialDistanceNormalizedDiagonal,
                  initialDistance.map { $0 / diagonal }
              ) else {
            throw VisualGroundingError.protocolViolation("initial routing evidence changed")
        }
        let expectedPair: [(String, VisualGroundingPoint)]
        if usedShowUI {
            expectedPair = valid.enumerated().flatMap { index, first in
                valid.dropFirst(index + 1).map { [first, $0] }
            }.min { lhs, rhs in
                Self.distance(lhs[0].1, lhs[1].1) < Self.distance(rhs[0].1, rhs[1].1)
            } ?? []
        } else {
            expectedPair = Array(valid.prefix(2))
        }
        guard expectedPair.count == 2,
              selectedPair == expectedPair.map(\.0) else {
            throw VisualGroundingError.protocolViolation("invalid selected model pair")
        }
        let expectedDistance = Self.distance(expectedPair[0].1, expectedPair[1].1) / diagonal
        let expectedPoint = VisualGroundingPoint(
            x: (expectedPair[0].1.x + expectedPair[1].1.x) / 2,
            y: (expectedPair[0].1.y + expectedPair[1].1.y) / 2
        )
        guard expectedDistance <= Self.agreementThreshold,
              Self.approximatelyEqual(selectedDistanceNormalizedDiagonal, expectedDistance),
              Self.approximatelyEqual(point.x, expectedPoint.x),
              Self.approximatelyEqual(point.y, expectedPoint.y) else {
            throw VisualGroundingError.protocolViolation("selected grounding result changed")
        }
        return self
    }

    private static func distance(
        _ first: VisualGroundingPoint?,
        _ second: VisualGroundingPoint?
    ) -> Double? {
        guard let first, let second else { return nil }
        return distance(first, second)
    }

    private static func distance(
        _ first: VisualGroundingPoint,
        _ second: VisualGroundingPoint
    ) -> Double {
        hypot(first.x - second.x, first.y - second.y)
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= 1e-9
    }

    private static func approximatelyEqual(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case (.some(let lhs), .some(let rhs)): approximatelyEqual(lhs, rhs)
        default: false
        }
    }

    private static func validate(
        _ point: VisualGroundingPoint,
        width: Int,
        height: Int
    ) throws {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0,
              point.x < Double(width), point.y < Double(height) else {
            throw VisualGroundingError.protocolViolation("grounded point is outside the screenshot")
        }
    }
}

protocol VisualGroundingClient: Sendable {
    func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision
    func shutdown() async -> [String]
}

enum VisualGroundingError: Error, Equatable, LocalizedError, Sendable {
    case unavailable(String)
    case protocolViolation(String)
    case worker(String)
    case timedOut
    case stopped

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "Visual grounding is unavailable: \(detail)"
        case .protocolViolation(let detail):
            "The visual-grounding worker violated its protocol: \(detail)"
        case .worker(let detail):
            "Visual grounding failed: \(detail)"
        case .timedOut:
            "Visual grounding exceeded its bounded deadline."
        case .stopped:
            "The visual-grounding worker is stopped."
        }
    }
}

struct VisualGroundingConfiguration: Equatable, Sendable {
    let pythonExecutable: URL
    let workerScript: URL
    let modelRoot: URL
    let requestRoot: URL
    let warmupImage: URL?
    let startupTimeout: Duration
    let requestTimeout: Duration

    static func local(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("LocalCodex", isDirectory: true)
        .appendingPathComponent("VisualGrounding", isDirectory: true)
        let runtimeRoot = environment["LOCALCODEX_GROUNDER_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? support
        let python = environment["LOCALCODEX_GROUNDER_PYTHON"].map {
            URL(fileURLWithPath: $0)
        } ?? runtimeRoot.appendingPathComponent("venv/bin/python")
        let modelRoot = environment["LOCALCODEX_GROUNDER_MODEL_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? runtimeRoot.appendingPathComponent("models", isDirectory: true)
        let resourceRoot = environment["LOCALCODEX_GROUNDER_RESOURCE_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? VisualGroundingResourceLocator.directoryURL
        guard let resourceRoot else {
            throw VisualGroundingError.unavailable("the bundled worker resources are missing")
        }
        return Self(
            pythonExecutable: python,
            workerScript: resourceRoot.appendingPathComponent("worker.py"),
            modelRoot: modelRoot,
            requestRoot: runtimeRoot.appendingPathComponent("Requests", isDirectory: true),
            warmupImage: resourceRoot.appendingPathComponent("warmup.png"),
            startupTimeout: .seconds(30),
            requestTimeout: .seconds(60)
        )
    }
}

enum VisualGroundingResourceLocator {
    static var directoryURL: URL? {
        candidateBundles.lazy.compactMap { bundle in
            bundle.url(
                forResource: "VisualGrounding",
                withExtension: nil
            )
        }.first
    }

    private static var candidateBundles: [Bundle] {
#if SWIFT_PACKAGE
        [Bundle.module, Bundle.main]
#else
        [Bundle.main]
#endif
    }
}

actor PythonVisualGroundingClient: VisualGroundingClient {
    private static let protocolVersion = 1
    private static let maximumResponseBuffer = 256 * 1024
    private static let maximumErrorBuffer = 16 * 1024

    private enum State {
        case stopped
        case starting
        case ready
        case stopping
    }

    private struct Pending {
        let continuation: CheckedContinuation<VisualGroundingDecision, Error>
        let request: VisualGroundingRequest
        let imageURL: URL
        let timeout: Task<Void, Never>
    }

    private struct WireEnvelope: Decodable {
        let id: String?
        let type: String?
        let ok: Bool?
        let error: String?
        let protocolVersion: Int?
        let methodVersion: String?

        enum CodingKeys: String, CodingKey {
            case id, type, ok, error
            case protocolVersion = "protocol_version"
            case methodVersion = "method_version"
        }
    }

    private let configuration: VisualGroundingConfiguration
    private var state = State.stopped
    private var child: OwnedChildProcess?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var outputReadTask: Task<Void, Never>?
    private var errorReadTask: Task<Void, Never>?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var readyWaiters = [UUID: CheckedContinuation<Void, Error>]()
    private var stopWaiters = [CheckedContinuation<[String], Never>]()
    private var startupTimeout: Task<Void, Never>?
    private var pending = [String: Pending]()
    private var lastStopIssues = [String]()

    init(configuration: VisualGroundingConfiguration) {
        self.configuration = configuration
    }

    static func local() -> any VisualGroundingClient {
        do {
            return PythonVisualGroundingClient(configuration: try .local())
        } catch {
            return UnavailableVisualGroundingClient(detail: error.localizedDescription)
        }
    }

    func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
        try validate(request)
        try await ensureStarted()
        guard case .ready = state, let input else { throw VisualGroundingError.stopped }

        let imageURL = configuration.requestRoot
            .appendingPathComponent(request.id.uuidString)
            .appendingPathExtension("png")
        let id = request.id.uuidString
        do {
            try writePrivateRequestImage(request.png, to: imageURL)
            let object: [String: Any] = [
                "id": id,
                "method": "ground",
                "image_path": imageURL.path,
                "target": request.target,
            ]
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let timeout = Task { [configuration] in
                        do { try await Task.sleep(for: configuration.requestTimeout) } catch { return }
                        await self.requestTimedOut(id: id)
                    }
                    pending[id] = Pending(
                        continuation: continuation,
                        request: request,
                        imageURL: imageURL,
                        timeout: timeout
                    )
                    do {
                        try input.write(contentsOf: data)
                    } catch {
                        timeout.cancel()
                        pending.removeValue(forKey: id)
                        try? FileManager.default.removeItem(at: imageURL)
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                Task { await self.cancelRequest(id: id) }
            }
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            throw error
        }
    }

    func shutdown() async -> [String] {
        if state == .stopping {
            return await withCheckedContinuation { stopWaiters.append($0) }
        }
        if state == .stopped, child == nil { return lastStopIssues }
        state = .stopping
        startupTimeout?.cancel()
        startupTimeout = nil
        failReadyWaiters(VisualGroundingError.stopped)
        failPending(VisualGroundingError.stopped)
        outputReadTask?.cancel()
        errorReadTask?.cancel()
        outputReadTask = nil
        errorReadTask = nil
        try? input?.close()
        try? output?.close()
        try? errorOutput?.close()
        input = nil
        output = nil
        errorOutput = nil
        let result = await child?.stop()
        child = nil
        state = .stopped
        outputBuffer.removeAll(keepingCapacity: false)
        let diagnostics = String(decoding: errorBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        errorBuffer.removeAll(keepingCapacity: false)
        var issues = result?.issues ?? []
        if result != nil, result?.succeeded == false, !diagnostics.isEmpty {
            issues.append("Visual-grounding stderr: \(diagnostics)")
        }
        lastStopIssues = issues
        completeStopWaiters(issues)
        return issues
    }

    private func validate(_ request: VisualGroundingRequest) throws {
        guard !request.png.isEmpty, request.png.count <= 16 * 1024 * 1024,
              request.width > 0, request.height > 0,
              request.width <= 8192, request.height <= 8192,
              request.width * request.height <= 16_777_216 else {
            throw VisualGroundingError.protocolViolation("invalid screenshot request")
        }
        guard request.target == request.target.trimmingCharacters(in: .whitespacesAndNewlines),
              !request.target.isEmpty,
              request.target.count <= 512,
              request.target.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator:
                      false
                  default:
                      true
                  }
              }) else {
            throw VisualGroundingError.protocolViolation("invalid target description")
        }
    }

    private func ensureStarted() async throws {
        switch state {
        case .ready:
            return
        case .starting:
            try await waitUntilReady()
        case .stopping:
            throw VisualGroundingError.stopped
        case .stopped:
            try start()
            try await waitUntilReady()
        }
    }

    private func start() throws {
        let fileManager = FileManager.default
        lastStopIssues.removeAll()
        guard fileManager.isExecutableFile(atPath: configuration.pythonExecutable.path) else {
            throw VisualGroundingError.unavailable(
                "run Scripts/install-visual-grounding.sh to install the pinned Python runtime"
            )
        }
        guard fileManager.isReadableFile(atPath: configuration.workerScript.path) else {
            throw VisualGroundingError.unavailable("the bundled worker script is missing")
        }
        for name in ["goclick-base-4bit", "gui-owl-2b", "showui-2b-4bit"] {
            let path = configuration.modelRoot.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: path.path) else {
                throw VisualGroundingError.unavailable(
                    "model \(name) is missing; run Scripts/install-visual-grounding.sh"
                )
            }
        }
        try prepareRequestDirectory(using: fileManager)
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let runtimeHome = configuration.requestRoot.deletingLastPathComponent().path
        let environment = [
            "HOME": runtimeHome,
            "TMPDIR": configuration.requestRoot.path,
            "PATH": "\(runtimeHome)/venv/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PYTHONUNBUFFERED": "1",
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONPATH": "",
            "HF_HUB_OFFLINE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "TOKENIZERS_PARALLELISM": "false",
        ]
        var arguments = [
            configuration.workerScript.path,
            "--model-root", configuration.modelRoot.path,
            "--request-root", configuration.requestRoot.path,
        ]
        if let warmupImage = configuration.warmupImage,
           fileManager.isReadableFile(atPath: warmupImage.path) {
            arguments += ["--warmup-image", warmupImage.path]
        }
        let spawned = try OwnedChildProcess(
            executableURL: configuration.pythonExecutable,
            arguments: arguments,
            environment: environment,
            inputDescriptor: stdin.fileHandleForReading.fileDescriptor,
            outputDescriptor: stdout.fileHandleForWriting.fileDescriptor,
            errorDescriptor: stderr.fileHandleForWriting.fileDescriptor
        )
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        child = spawned
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errorOutput = stderr.fileHandleForReading
        state = .starting
        outputReadTask = makeOutputReadTask(stdout.fileHandleForReading)
        errorReadTask = makeErrorReadTask(stderr.fileHandleForReading)
        startupTimeout = Task { [configuration] in
            do { try await Task.sleep(for: configuration.startupTimeout) } catch { return }
            await self.startTimedOut()
        }
    }

    private func waitUntilReady() async throws {
        let waiterID = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if case .ready = state {
                    continuation.resume(returning: ())
                } else {
                    readyWaiters[waiterID] = continuation
                }
            }
        }, onCancel: {
            Task<Void, Never> { await self.cancelReadyWaiter(id: waiterID) }
        })
    }

    private func cancelReadyWaiter(id: UUID) {
        readyWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func prepareRequestDirectory(using fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: configuration.requestRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let values = try configuration.requestRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw VisualGroundingError.unavailable("the request directory is not a regular directory")
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: configuration.requestRoot.path
        )
        let children = try fileManager.contentsOfDirectory(
            at: configuration.requestRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for child in children where child.pathExtension == "png" {
            guard UUID(uuidString: child.deletingPathExtension().lastPathComponent) != nil else {
                continue
            }
            try fileManager.removeItem(at: child)
        }
    }

    private func writePrivateRequestImage(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
        var isOpen = true
        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    throw POSIXError(.EINVAL)
                }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written == -1 && errno == EINTR {
                        continue
                    } else {
                        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                        throw POSIXError(code)
                    }
                }
            }
            guard Darwin.close(descriptor) == 0 else {
                isOpen = false
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                throw POSIXError(code)
            }
            isOpen = false
        } catch {
            if isOpen { _ = Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func makeOutputReadTask(_ handle: FileHandle) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let data = handle.availableData
                guard !data.isEmpty else {
                    await self?.receiveOutput(Data())
                    return
                }
                await self?.receiveOutput(data)
            }
        }
    }

    private func makeErrorReadTask(_ handle: FileHandle) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                await self?.receiveError(data)
            }
        }
    }

    private func receiveOutput(_ data: Data) async {
        guard !data.isEmpty else {
            if state != .stopping {
                await failWorker(VisualGroundingError.worker(workerExitDetail()))
            }
            return
        }
        outputBuffer.append(data)
        guard outputBuffer.count <= Self.maximumResponseBuffer else {
            await failWorker(VisualGroundingError.protocolViolation("response buffer exceeded its bound"))
            return
        }
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                try receiveLine(line)
            } catch {
                await failWorker(error)
                return
            }
        }
    }

    private func receiveLine(_ data: Data) throws {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(WireEnvelope.self, from: data)
        if envelope.type == "ready" {
            guard case .starting = state,
                  envelope.protocolVersion == Self.protocolVersion,
                  envelope.methodVersion == VisualGroundingDecision.methodVersion else {
                throw VisualGroundingError.protocolViolation("invalid ready message")
            }
            startupTimeout?.cancel()
            startupTimeout = nil
            state = .ready
            let waiters = Array(readyWaiters.values)
            readyWaiters.removeAll()
            waiters.forEach { $0.resume(returning: ()) }
            return
        }
        guard let id = envelope.id, let item = pending.removeValue(forKey: id) else {
            throw VisualGroundingError.protocolViolation("response had no matching request")
        }
        item.timeout.cancel()
        try? FileManager.default.removeItem(at: item.imageURL)
        guard envelope.ok == true else {
            item.continuation.resume(
                throwing: VisualGroundingError.worker(envelope.error ?? "unknown worker error")
            )
            return
        }
        do {
            let decision = try decoder.decode(VisualGroundingDecision.self, from: data)
                .validated(for: item.request)
            item.continuation.resume(returning: decision)
        } catch {
            item.continuation.resume(throwing: error)
        }
    }

    private func receiveError(_ data: Data) {
        guard !data.isEmpty else { return }
        let remaining = max(0, Self.maximumErrorBuffer - errorBuffer.count)
        errorBuffer.append(data.prefix(remaining))
    }

    private func requestTimedOut(id: String) async {
        guard pending[id] != nil else { return }
        await failWorker(VisualGroundingError.timedOut)
    }

    private func cancelRequest(id: String) async {
        guard pending[id] != nil else { return }
        await failWorker(CancellationError())
    }

    private func startTimedOut() async {
        guard case .starting = state else { return }
        await failWorker(VisualGroundingError.timedOut)
    }

    private func failWorker(_ error: Error) async {
        guard state != .stopping else { return }
        state = .stopping
        startupTimeout?.cancel()
        startupTimeout = nil
        failReadyWaiters(error)
        failPending(error)
        outputReadTask?.cancel()
        errorReadTask?.cancel()
        outputReadTask = nil
        errorReadTask = nil
        try? input?.close()
        try? output?.close()
        try? errorOutput?.close()
        input = nil
        output = nil
        errorOutput = nil
        let result = await child?.stop()
        child = nil
        outputBuffer.removeAll(keepingCapacity: false)
        let diagnostics = String(decoding: errorBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        errorBuffer.removeAll(keepingCapacity: false)
        var issues = result?.issues ?? []
        if result != nil, result?.succeeded == false, !diagnostics.isEmpty {
            issues.append("Visual-grounding stderr: \(diagnostics)")
        }
        lastStopIssues = issues
        state = .stopped
        completeStopWaiters(issues)
    }

    private func failReadyWaiters(_ error: Error) {
        let waiters = Array(readyWaiters.values)
        readyWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func failPending(_ error: Error) {
        let values = Array(pending.values)
        pending.removeAll()
        for item in values {
            item.timeout.cancel()
            try? FileManager.default.removeItem(at: item.imageURL)
            item.continuation.resume(throwing: error)
        }
    }

    private func completeStopWaiters(_ issues: [String]) {
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume(returning: issues) }
    }

    private func workerExitDetail() -> String {
        let detail = String(decoding: errorBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "the worker exited before replying" : detail
    }
}

private struct UnavailableVisualGroundingClient: VisualGroundingClient {
    let detail: String

    func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
        throw VisualGroundingError.unavailable(detail)
    }

    func shutdown() async -> [String] { [] }
}

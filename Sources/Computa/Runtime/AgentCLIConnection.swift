import Darwin
import Foundation

enum AgentCLIError: LocalizedError, Sendable {
    case installationRequired(String), signInRequired(String), unavailable(String), protocolError(String), cancelled
    var errorDescription: String? {
        switch self {
        case .installationRequired(let reason), .signInRequired(let reason), .unavailable(let reason), .protocolError(let reason): reason
        case .cancelled: "CLI task interrupted."
        }
    }
}

/// JSON-RPC rejected the method or arguments before dispatch. A transport
/// failure or an arbitrary internal server error cannot establish that.
struct AgentCLIInvalidRequest: LocalizedError, Sendable {
    let message: String
    var code: Int? = nil
    var errorDescription: String? { message }
}

/// One private stdio connection per task. Only its own process group is stopped.
actor AgentCLIConnection {
    typealias MessageHandler = @Sendable (Data) async -> Void
    private let reportInvalidRequests: Bool
    private let codexProtocol: Bool
    nonisolated var processIdentifier: pid_t { process.processIdentifier }
    private let process: OwnedChildProcess
    private let input: FileHandle
    private let output: FileHandle
    private let onClose: (@Sendable () -> Void)?
    private let handler: MessageHandler
    private var reader: Task<Void, Never>?
    private var sequence = 0
    private var stopped = false
    private var requests: [Int: CheckedContinuation<Data, Error>] = [:]

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String],
         codexProtocol: Bool = false, reportInvalidRequests: Bool = false, onClose: (@Sendable () -> Void)? = nil, handler: @escaping MessageHandler) throws {
        self.onClose = onClose
        self.codexProtocol = codexProtocol
        self.reportInvalidRequests = reportInvalidRequests
        let stdin = Pipe(), stdout = Pipe()
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw POSIXError(.EIO) }
        process = try OwnedChildProcess(executableURL: executable, arguments: arguments,
            environment: environment, workingDirectory: directory,
            inputDescriptor: stdin.fileHandleForReading.fileDescriptor,
            outputDescriptor: stdout.fileHandleForWriting.fileDescriptor)
        self.input = stdin.fileHandleForWriting
        self.output = stdout.fileHandleForReading
        self.handler = handler
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
    }

    private func startReading() {
        guard reader == nil else { return }
        reader = Task.detached { [weak self, output] in
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            defer { try? output.close() }
            do {
                while true {
                    // An interactive agent waits for our next frame before writing more.
                    // A single pipe read returns the available bytes immediately.
                    let count = bytes.withUnsafeMutableBytes {
                        Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count)
                    }
                    if count == 0 { break }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw POSIXError(.EIO) }
                    buffer.append(contentsOf: bytes.prefix(count))
                    while let end = buffer.firstIndex(of: 10) {
                        guard buffer.distance(from: buffer.startIndex, to: end) <= 8 * 1024 * 1024 else {
                            throw AgentCLIError.protocolError("CLI response exceeded its frame limit.")
                        }
                        let data = Data(buffer[..<end])
                        buffer = Data(buffer[buffer.index(after: end)...])
                        if !data.isEmpty { try await self?.receive(data) }
                    }
                    guard buffer.count <= 8 * 1024 * 1024 else { throw AgentCLIError.protocolError("CLI response exceeded its frame limit.") }
                }
                await self?.close(reason: .protocolError("The CLI closed its connection."))
            } catch { await self?.close(reason: .protocolError("The CLI returned an invalid response.")) }
        }
    }

    private func receive(_ data: Data) async throws {
        guard !stopped else { return }
        guard let msg = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentCLIError.protocolError("Invalid CLI protocol message.")
        }
        let hasVersion = msg["jsonrpc"] != nil
        let version = msg["jsonrpc"] as? String
        guard version == "2.0" || (codexProtocol && !hasVersion) else {
            throw AgentCLIError.protocolError("Invalid CLI protocol message.")
        }
        if msg["method"] != nil { await handler(data); return }
        guard let id = msg["id"] as? Int, let waiting = requests.removeValue(forKey: id) else { return }
        if let error = msg["error"] as? [String: Any] {
            let reason = error["message"] as? String ?? "CLI request failed."
            let detail = String(reason.prefix(1200))
            let code = error["code"] as? Int
            if reportInvalidRequests && (code == -32601 || code == -32602) {
                waiting.resume(throwing: AgentCLIInvalidRequest(message: detail, code: code))
            } else {
                waiting.resume(throwing: code == -32000 ? AgentCLIError.signInRequired(detail) : .protocolError(detail))
            }
        } else if let result = msg["result"], JSONSerialization.isValidJSONObject(result) {
            do { waiting.resume(returning: try JSONSerialization.data(withJSONObject: result)) }
            catch { waiting.resume(throwing: error) }
        } else { waiting.resume(throwing: AgentCLIError.protocolError("The CLI omitted its result.")) }
    }

    func send(_ data: Data) throws {
        guard !stopped else { throw AgentCLIError.cancelled }
        try input.write(contentsOf: data + Data([10]))
    }

    func request(_ method: String, params: Data, timeout: Duration) async throws -> Data {
        guard !stopped else { throw AgentCLIError.cancelled }
        startReading()
        sequence += 1
        let id = sequence
        var frame: [String: Any] = ["method": method, "id": id, "params": try JSONSerialization.jsonObject(with: params)]
        if !codexProtocol { frame["jsonrpc"] = "2.0" }
        let message = try JSONSerialization.data(withJSONObject: frame)
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            guard self.requests[id] != nil else { return }
            await self.close(reason: .protocolError("The CLI timed out during " + method + "."))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do { try send(message); requests[id] = continuation }
                catch { continuation.resume(throwing: error) }
            }
        } onCancel: { Task { await self.close(reason: .cancelled) } }
    }

    @discardableResult
    func close(reason: AgentCLIError = .cancelled) async -> [String] {
        if !stopped {
            stopped = true
            onClose?()
            let waiting = requests
            requests.removeAll()
            for continuation in waiting.values { continuation.resume(throwing: reason) }
            try? input.close()
        }
        let report = await process.stop()
        return report.issues
    }
}

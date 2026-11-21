import Foundation
import Network

/// Bounded, single-request HTTP/1.1 framing shared by Computa's loopback services.
enum LoopbackHTTP {
    enum Failure: Error { case invalidRequest, disconnected }

    static func start(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let once = LoopbackListenerReady(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port { once.finish(.success(port.rawValue)) }
                    else { once.finish(.failure(Failure.disconnected)) }
                case .failed: once.finish(.failure(Failure.disconnected))
                case .cancelled: once.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    struct HTTPRequest: Sendable { let method: String; let path: String; let headers: [String: String]; let body: Data }
    static func parseRequest(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= 2_097_152 else { throw Failure.invalidRequest }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 16_384 else { throw Failure.invalidRequest }; return nil
        }
        guard separator.lowerBound <= 16_384, let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else { throw Failure.invalidRequest }
        let lines = head.components(separatedBy: "\r\n"), start = lines[0].components(separatedBy: " ")
        guard start.count == 3, start[2] == "HTTP/1.1", ["GET", "POST"].contains(start[0]) else { throw Failure.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.invalidRequest }
            let name = String(line[..<colon]).lowercased(), value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[name] == nil,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidRequest }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? (start[0] == "GET" ? "0" : "")), (0...2_000_000).contains(length),
              start[0] != "POST" || length > 0, start[0] != "GET" || length == 0 else { throw Failure.invalidRequest }
        let available = data.count - separator.upperBound
        if available < length { return nil }
        guard available == length else { throw Failure.invalidRequest }
        return HTTPRequest(method: start[0], path: start[1], headers: headers, body: Data(data[separator.upperBound...]))
    }
    static func readRequest(_ connection: NWConnection) async throws -> HTTPRequest {
        var data = Data()
        while true {
            let next: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                    if error != nil { continuation.resume(throwing: Failure.invalidRequest) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: Failure.invalidRequest) }
                }
            }
            data.append(next); if let request = try parseRequest(data) { return request }
        }
    }
    static func send(_ connection: NWConnection, status: String, type: String, body: Data) async throws {
        var data = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8); data.append(body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: Failure.disconnected) } else { continuation.resume() }
            })
        }
    }
}

private final class LoopbackListenerReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock(); value?.resume(with: result)
    }
}

import CryptoKit
import Darwin
import Foundation
import OSLog

/// Handoff from an orderly shutdown to the next app process. A receipt names
/// an interrupted turn. Prompts and tool payloads stay in the existing chat.
struct AgentRestartStore: Sendable {
    struct Turn: Equatable, Sendable {
        let taskID: String
        let threadID: String
        let turnID: String
    }

    struct Receipt: Codable, Equatable, Sendable {
        let threadID: String
        let turnID: String
        let model: String
        let accessMode: AccessMode
        let requestDigest: String

        var filename: String { AgentRestartStore.digest(threadID + "\u{0}" + turnID) + ".json" }
    }

    let directory: URL
    static let continuation = "Kolmogor reopened while this task was running. Continue the existing request from the last confirmed step in this chat. Check the current state before taking action. Do not repeat a completed action. If a previous action's outcome cannot be verified, pause and ask."
    // Native tool scope and completion checks still belong to the original request.
    @TaskLocal static var originalRequest: String?

    static func digest(_ request: String) -> String {
        SHA256.hash(data: Data(request.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func save(_ receipt: Receipt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent(receipt.filename), options: .atomic)
    }

    func pending() throws -> [Receipt] {
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return try files.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            let receipt: Receipt
            do { receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url)) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
            catch is DecodingError {
                Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "AgentRestart").error("Ignoring an unreadable restart receipt")
                return nil
            }
            guard receipt.filename == url.lastPathComponent else { return nil }
            return receipt
        }
    }

    /// Moving the receipt is the claim. A crash after the move leaves it outside
    /// the pending set, even if deletion or dispatch has not happened yet.
    func claim(_ receipt: Receipt) throws -> Bool {
        let source = directory.appendingPathComponent(receipt.filename)
        let claimed = directory.appendingPathComponent(UUID().uuidString + ".claimed")
        if rename(source.path, claimed.path) != 0 {
            let code = errno
            if code == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        _ = unlink(claimed.path)
        return true
    }
}

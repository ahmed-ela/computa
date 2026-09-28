import CryptoKit
import Darwin
import Foundation

/// These durable diagnostics accept bounded counts and a fixed runtime code,
/// never page text, model prose, tool arguments or an invented failure cause.
enum ComputerOutcomeDiagnostic {
    enum Kind: String, Sendable {
        case unverified = "computer_outcome_unverified"
        case recoveryExhausted = "runtime_recovery_exhausted"

        var message: String {
            switch self {
            case .unverified:
                "The requested computer-use outcome could not be verified. This attempt does not establish completion or an empty search result. You can continue in this chat."
            case .recoveryExhausted:
                "Computer-use recovery stopped after repeated or unavailable actions. The requested outcome remains unverified. You can continue in this chat."
            }
        }
    }

    struct Value: Sendable {
        let message: String
        let diagnosticText: String
    }

    static let nextStep = "Use fresh observations in a new attempt. Do not treat this failed attempt as a completed action or an empty result."

    static func make(kind: Kind, unresolvedOperations: Int, failedOperations: Int) throws -> Value {
        guard (1 ... ComputerActionEvidence.maximumOperations).contains(unresolvedOperations),
              (0 ... unresolvedOperations).contains(failedOperations) else {
            throw NativeFailureEvidenceStore.StoreError.invalid("invalid outcome counts")
        }
        let object: [String: Any] = [
            "type": "native_tool_failure", "error": ["code": kind.rawValue, "message": kind.message],
            "cause": "undetermined", "website_status": "not_observed", "action_outcome": "unverified",
            "retry_policy": "stop_for_turn", "unresolved_operations": unresolvedOperations,
            "failed_operations": failedOperations, "next_step": nextStep,
        ]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return Value(message: kind.message, diagnosticText: String(decoding: bytes, as: UTF8.self))
    }
}

/// App-owned evidence, not an assistant message or an App Server tool receipt.
/// A successful append has synced a private atomic replacement and its directory.
/// Bounds fail closed instead of evicting a previous completed action.
struct NativeFailureEvidenceStore: Sendable {
    struct Record: Codable, Equatable, Sendable {
        let threadID: String
        let turnID: String
        let callID: String
        let toolName: String
        let message: String
        let diagnosticText: String
        let timestamp: Date

        fileprivate func hasSameEvidence(as other: Self) -> Bool {
            threadID == other.threadID && turnID == other.turnID && callID == other.callID
                && toolName == other.toolName && message == other.message && diagnosticText == other.diagnosticText
        }
    }

    enum StoreError: LocalizedError, Equatable {
        case invalid(String)
        case identityConflict
        case capacityExceeded
        case filesystem(String, Int32)

        var errorDescription: String? {
            switch self {
            case .invalid(let detail): "Native failure evidence is invalid: \(detail)."
            case .identityConflict: "Native failure evidence conflicts with an existing call identity."
            case .capacityExceeded: "Native failure evidence reached its bounded storage capacity."
            case .filesystem(let operation, let code): "Could not persist native failure evidence (\(operation), errno \(code))."
            }
        }
    }

    static let maximumRecords = 16
    static let maximumFileBytes = 64 * 1024
    private static let processLock = NSLock()
    private let directory: URL

    private struct Envelope: Codable {
        let version: Int
        let threadID: String
        var records: [Record]
    }

    init(directory: URL) throws {
        guard directory.isFileURL else { throw StoreError.invalid("directory is not a file URL") }
        self.directory = directory
        // Creation does not follow an existing final-component symlink: opening
        // below rejects it, including a dangling link. Never alter existing modes.
        var metadata = stat()
        if lstat(directory.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR else { throw StoreError.invalid("directory is not a real directory") }
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } else {
            throw StoreError.filesystem("inspect directory", errno)
        }
        let descriptor = try openDirectory()
        close(descriptor)
    }

    @discardableResult
    func append(_ record: Record) throws -> Record {
        try validate(record)
        return try Self.processLock.withLock {
            let descriptor = try openDirectory(lock: LOCK_EX)
            defer { close(descriptor) }
            var records = try load(threadID: record.threadID, directoryDescriptor: descriptor)
            if let existing = records.first(where: { $0.turnID == record.turnID && $0.callID == record.callID }) {
                guard existing.hasSameEvidence(as: record) else { throw StoreError.identityConflict }
                guard fsync(descriptor) == 0 else { throw StoreError.filesystem("sync duplicate evidence", errno) }
                return existing
            }
            guard records.count < Self.maximumRecords else { throw StoreError.capacityExceeded }
            records.append(record)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(Envelope(version: 1, threadID: record.threadID, records: records))
            guard bytes.count <= Self.maximumFileBytes else { throw StoreError.capacityExceeded }
            try replace(bytes, named: filename(record.threadID), directoryDescriptor: descriptor)
            // Fail closed even after replacement if independent decoding does
            // not produce the exact evidence we meant to make durable.
            guard try load(threadID: record.threadID, directoryDescriptor: descriptor) == records else {
                throw StoreError.invalid("readback differs from saved evidence")
            }
            return record
        }
    }

    func load(threadID: String) throws -> [Record] {
        try validateIdentity(threadID)
        return try Self.processLock.withLock {
            let descriptor = try openDirectory(lock: LOCK_SH)
            defer { close(descriptor) }
            return try load(threadID: threadID, directoryDescriptor: descriptor)
        }
    }

    private func openDirectory(lock: Int32? = nil) throws -> Int32 {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StoreError.filesystem("open evidence directory", errno) }
        // The directory inode is stable across atomic file replacements. Lock
        // it, not the replaceable JSON inode, so separate app processes cannot
        // read the same version and then overwrite each other's new records.
        // Closing the descriptor releases its advisory lock on every exit path.
        if let lock {
            while flock(descriptor, lock) != 0 {
                if errno == EINTR { continue }
                let code = errno
                close(descriptor)
                throw StoreError.filesystem("lock evidence directory", code)
            }
        }
        return descriptor
    }

    private func filename(_ threadID: String) -> String {
        SHA256.hash(data: Data(threadID.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func load(threadID: String, directoryDescriptor: Int32) throws -> [Record] {
        // NONBLOCK avoids hanging on a hostile FIFO before its type is checked.
        let descriptor = openat(directoryDescriptor, filename(threadID), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return [] }
            throw StoreError.filesystem("open evidence file", errno)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw StoreError.filesystem("inspect evidence file", errno) }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o600 else {
            throw StoreError.invalid("evidence file is not a private owned regular file")
        }
        guard metadata.st_size > 0, metadata.st_size <= Self.maximumFileBytes else { throw StoreError.capacityExceeded }
        var bytes = Data(count: Self.maximumFileBytes + 1)
        let count = try bytes.withUnsafeMutableBytes { buffer -> Int in
            var count = 0
            while count < buffer.count {
                let result = read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw StoreError.filesystem("read evidence", errno)
                }
                if result == 0 { return count }
                count += result
            }
            return count
        }
        guard count == metadata.st_size, count <= Self.maximumFileBytes else { throw StoreError.invalid("evidence file changed during read") }
        bytes.count = count
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["version", "threadID", "records"],
              let rawRecords = object["records"] as? [[String: Any]],
              rawRecords.allSatisfy({ Set($0.keys) == ["threadID", "turnID", "callID", "toolName", "message", "diagnosticText", "timestamp"] }) else {
            throw StoreError.invalid("unrecognized evidence fields")
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.version == 1, envelope.threadID == threadID,
              !envelope.records.isEmpty, envelope.records.count <= Self.maximumRecords else {
            throw StoreError.invalid("unsupported version, thread, or record count")
        }
        var identities = Set<[String]>()
        for record in envelope.records {
            try validate(record)
            guard record.threadID == threadID, identities.insert([record.turnID, record.callID]).inserted else {
                throw StoreError.invalid("mismatched thread or duplicate call identity")
            }
        }
        return envelope.records
    }

    private func replace(_ bytes: Data, named name: String, directoryDescriptor: Int32) throws {
        let temporaryName = ".native-failure-\(UUID().uuidString).tmp"
        let descriptor = openat(directoryDescriptor, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StoreError.filesystem("create private temporary evidence", errno) }
        defer {
            close(descriptor)
            // This exact private temporary name is created and owned here.
            _ = unlinkat(directoryDescriptor, temporaryName, 0)
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw StoreError.filesystem("set evidence permissions", errno) }
        try bytes.withUnsafeBytes { buffer in
            var count = 0
            while count < buffer.count {
                let result = write(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw StoreError.filesystem("write evidence", errno)
                }
                guard result > 0 else { throw StoreError.invalid("zero-length evidence write") }
                count += result
            }
        }
        guard fsync(descriptor) == 0 else { throw StoreError.filesystem("sync evidence file", errno) }
        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, name) == 0 else {
            throw StoreError.filesystem("atomically replace evidence", errno)
        }
        guard fsync(directoryDescriptor) == 0 else { throw StoreError.filesystem("sync evidence directory", errno) }
    }

    private func validateIdentity(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 256, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw StoreError.invalid("empty, oversized, or control-character identity")
        }
    }

    private func validate(_ record: Record) throws {
        for identity in [record.threadID, record.turnID, record.callID] { try validateIdentity(identity) }
        guard !record.toolName.isEmpty, record.toolName.utf8.count <= 128,
              !record.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record.message.utf8.count <= 2_048,
              record.diagnosticText.utf8.count <= 8_192, record.timestamp.timeIntervalSinceReferenceDate.isFinite,
              let diagnostic = try JSONSerialization.jsonObject(with: Data(record.diagnosticText.utf8)) as? [String: Any],
              diagnostic["type"] as? String == "native_tool_failure",
              let error = diagnostic["error"] as? [String: Any], Set(error.keys) == ["code", "message"],
              let code = error["code"] as? String,
              let errorMessage = error["message"] as? String, !errorMessage.isEmpty, errorMessage.utf8.count <= 2_048,
              diagnostic["cause"] as? String == "undetermined", diagnostic["website_status"] as? String == "not_observed",
              let nextStep = diagnostic["next_step"] as? String, !nextStep.isEmpty else {
            throw StoreError.invalid("record is not bounded native failure evidence")
        }
        switch code {
        case "application_activation_failed":
            // Preserve the existing on-disk activation schema and PID checks.
            guard Set(diagnostic.keys) == ["type", "error", "process_id", "cause", "website_status", "action_outcome", "next_step"],
                  let processID = diagnostic["process_id"] as? NSNumber, String(cString: processID.objCType) != "c",
                  processID.doubleValue > 0, processID.doubleValue <= Double(Int32.max),
                  processID.doubleValue == processID.doubleValue.rounded(),
                  diagnostic["action_outcome"] as? String == "not_confirmed" else {
                throw StoreError.invalid("record is not bounded native activation-failure evidence")
            }
        case "chrome_navigation_recovery_required":
            // This explicit alternative has no PID, URL, or browser-state
            // fields. Human-readable text is bounded inert evidence, not
            // authority; older copy must remain readable after wording changes.
            guard Set(diagnostic.keys) == ["type", "error", "cause", "website_status", "action_outcome", "tab_state", "retry_policy", "next_step"],
                  record.toolName == "computer_v2_open",
                  diagnostic["action_outcome"] as? String == "navigation_not_confirmed",
                  diagnostic["tab_state"] as? String == "preserved_if_created",
                  diagnostic["retry_policy"] as? String == "stop_for_turn" else {
                throw StoreError.invalid("record is not redacted Chrome navigation-recovery evidence")
            }
        case "computer_outcome_unverified", "runtime_recovery_exhausted":
            guard let kind = ComputerOutcomeDiagnostic.Kind(rawValue: code),
                  Set(diagnostic.keys) == ["type", "error", "cause", "website_status", "action_outcome", "retry_policy", "unresolved_operations", "failed_operations", "next_step"],
                  diagnostic["action_outcome"] as? String == "unverified",
                  diagnostic["retry_policy"] as? String == "stop_for_turn",
                  errorMessage == kind.message, record.message == kind.message,
                  nextStep == ComputerOutcomeDiagnostic.nextStep,
                  let unresolved = diagnostic["unresolved_operations"] as? NSNumber,
                  let failed = diagnostic["failed_operations"] as? NSNumber,
                  CFGetTypeID(unresolved) != CFBooleanGetTypeID(), CFGetTypeID(failed) != CFBooleanGetTypeID(),
                  unresolved.doubleValue.isFinite, failed.doubleValue.isFinite,
                  unresolved.doubleValue == Double(unresolved.intValue), failed.doubleValue == Double(failed.intValue),
                  (1 ... ComputerActionEvidence.maximumOperations).contains(unresolved.intValue),
                  (0 ... unresolved.intValue).contains(failed.intValue),
                  (kind == .unverified ? record.toolName == "computer_outcome"
                   : (record.toolName.hasPrefix("computer_v2_") || record.toolName == "computer" || record.toolName.hasPrefix("desktop_"))) else {
                throw StoreError.invalid("record is not redacted runtime outcome evidence")
            }
        default:
            throw StoreError.invalid("unrecognized native failure evidence code")
        }
    }
}

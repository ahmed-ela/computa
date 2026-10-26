import Foundation
import Darwin

private enum APICorrectionDiagnosticCoding {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func keys(_ decoder: any Decoder) throws -> Set<String> {
        Set(try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue))
    }
    static func requireKeys<K: CodingKey & CaseIterable>(_ decoder: any Decoder, _ keys: K.Type) throws {
        guard try self.keys(decoder) == Set(K.allCases.map(\.stringValue)) else { throw invalid(decoder) }
    }
    static func invalid(_ decoder: any Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid finite API correction diagnostic."))
    }
}

/// Provider-reported billable counts. These are never the native context gauge.
struct APIModelCorrectionUsage: Codable, Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let cachedInputTokens: Int
    let reasoningOutputTokens: Int

    func adding(_ other: Self) throws -> Self {
        func sum(_ a: Int, _ b: Int) throws -> Int {
            let result = a.addingReportingOverflow(b)
            guard !result.overflow else { throw APIModelResponseCodec.Failure.invalidResponse }
            return result.partialValue
        }
        return try .init(inputTokens: sum(inputTokens, other.inputTokens), outputTokens: sum(outputTokens, other.outputTokens),
                         totalTokens: sum(totalTokens, other.totalTokens), cachedInputTokens: sum(cachedInputTokens, other.cachedInputTokens),
                         reasoningOutputTokens: sum(reasoningOutputTokens, other.reasoningOutputTokens))
    }

    var responseUsage: [String: Any] {
        ["input_tokens": inputTokens, "output_tokens": outputTokens, "total_tokens": totalTokens,
         "input_tokens_details": ["cached_tokens": cachedInputTokens], "output_tokens_details": ["reasoning_tokens": reasoningOutputTokens]]
    }
}

extension APIModelCorrectionUsage {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case inputTokens, outputTokens, totalTokens, cachedInputTokens, reasoningOutputTokens
    }
    init(from decoder: any Decoder) throws {
        try APICorrectionDiagnosticCoding.requireKeys(decoder, CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(inputTokens: try values.decode(Int.self, forKey: .inputTokens),
            outputTokens: try values.decode(Int.self, forKey: .outputTokens),
            totalTokens: try values.decode(Int.self, forKey: .totalTokens),
            cachedInputTokens: try values.decode(Int.self, forKey: .cachedInputTokens),
            reasoningOutputTokens: try values.decode(Int.self, forKey: .reasoningOutputTokens))
    }
}

/// Three exclusive, fsynced finite records form one correction journal.
/// The first known usage is durable before any corrective request can start.
/// No prompt, arguments, reasoning, tool schema, URL or credential is stored.
struct APIModelCorrectionAccounting: Sendable {
    enum Failure: Error { case unavailable }
    enum Outcome: String, Codable, Sendable {
        case responseValidated = "response_validated", argumentsRejected = "arguments_rejected"
        case transportFailed = "transport_failed", decodeFailed = "decode_failed"
        case cancelled, timedOut = "timed_out", budgetExhausted = "budget_exhausted"
    }
    /// An observation of the first rejected response, never argument values or
    /// authority to correct it. Existing decoder gates remain authoritative.
    struct FirstValidation: Codable, Equatable, Sendable {
        struct SchemaFailure: Codable, Equatable, Sendable {
            let toolIndex: Int
            let constraint: APIModelResponseCodec.SchemaConstraint
            var location: APIModelResponseCodec.BuiltinSchemaLocation? = nil
            init(toolIndex: Int, constraint: APIModelResponseCodec.SchemaConstraint,
                 location: APIModelResponseCodec.BuiltinSchemaLocation? = nil) {
                self.toolIndex = toolIndex; self.constraint = constraint; self.location = location
            }
            private enum CodingKeys: String, CodingKey, CaseIterable { case toolIndex, constraint, location }
            init(from decoder: any Decoder) throws {
                let keys = try APICorrectionDiagnosticCoding.keys(decoder)
                guard [Set(["toolIndex", "constraint"]), Set(CodingKeys.allCases.map(\.stringValue))].contains(keys) else {
                    throw APICorrectionDiagnosticCoding.invalid(decoder)
                }
                let values = try decoder.container(keyedBy: CodingKeys.self)
                let index = try values.decode(Int.self, forKey: .toolIndex)
                guard (0..<128).contains(index) else { throw APICorrectionDiagnosticCoding.invalid(decoder) }
                self.init(toolIndex: index, constraint: try values.decode(APIModelResponseCodec.SchemaConstraint.self, forKey: .constraint),
                    location: keys.contains("location") ? try values.decode(APIModelResponseCodec.BuiltinSchemaLocation.self, forKey: .location) : nil)
            }
        }
        let reason: APIModelResponseCodec.ArgumentValidationDiagnostic.Reason
        let callCount: Int
        let rejectedCount: Int
        let schemaFailures: [SchemaFailure]

        init?(_ diagnostic: APIModelResponseCodec.ArgumentValidationDiagnostic) {
            let failures = diagnostic.schemaFailures ?? []
            guard (1...128).contains(diagnostic.callCount), (1...diagnostic.callCount).contains(diagnostic.rejectedCount),
                  failures.count <= 2, failures.allSatisfy({ (0..<128).contains($0.toolIndex) && ($0.location?.isConsistent ?? true) }) else { return nil }
            reason = diagnostic.reason; callCount = diagnostic.callCount; rejectedCount = diagnostic.rejectedCount
            schemaFailures = failures.map { .init(toolIndex: $0.toolIndex, constraint: $0.constraint, location: $0.location) }
        }
        private enum CodingKeys: String, CodingKey, CaseIterable { case reason, callCount, rejectedCount, schemaFailures }
        init(from decoder: any Decoder) throws {
            try APICorrectionDiagnosticCoding.requireKeys(decoder, CodingKeys.self)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            reason = try values.decode(APIModelResponseCodec.ArgumentValidationDiagnostic.Reason.self, forKey: .reason)
            callCount = try values.decode(Int.self, forKey: .callCount)
            rejectedCount = try values.decode(Int.self, forKey: .rejectedCount)
            schemaFailures = try values.decode([SchemaFailure].self, forKey: .schemaFailures)
            guard (1...128).contains(callCount), (1...callCount).contains(rejectedCount), schemaFailures.count <= 2 else {
                throw APICorrectionDiagnosticCoding.invalid(decoder)
            }
        }
    }
    struct Ticket: Sendable {
        let id: UUID
        let taskID: String
        let threadID: String
        let turnID: String
        let firstUsage: APIModelCorrectionUsage
        var firstValidation: FirstValidation? = nil
    }
    struct Record: Codable, Sendable {
        let schemaVersion: Int
        let scope: String
        let correctionID: UUID
        let taskID: String
        let threadID: String
        let turnID: String
        let phase: String
        let secondRequestClaimed: Bool
        let firstUsage: APIModelCorrectionUsage
        let secondUsage: APIModelCorrectionUsage?
        let secondUsageUnknown: Bool
        let outcome: Outcome?
        let firstValidation: FirstValidation?
        let secondValidation: FirstValidation?
        init(schemaVersion: Int, scope: String, correctionID: UUID, taskID: String, threadID: String, turnID: String,
             phase: String, secondRequestClaimed: Bool, firstUsage: APIModelCorrectionUsage,
             secondUsage: APIModelCorrectionUsage?, secondUsageUnknown: Bool, outcome: Outcome?, firstValidation: FirstValidation?,
             secondValidation: FirstValidation? = nil) {
            self.schemaVersion = schemaVersion; self.scope = scope; self.correctionID = correctionID
            self.taskID = taskID; self.threadID = threadID; self.turnID = turnID; self.phase = phase
            self.secondRequestClaimed = secondRequestClaimed; self.firstUsage = firstUsage; self.secondUsage = secondUsage
            self.secondUsageUnknown = secondUsageUnknown; self.outcome = outcome; self.firstValidation = firstValidation
            self.secondValidation = secondValidation
        }
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion, scope, correctionID, taskID, threadID, turnID, phase, secondRequestClaimed,
                 firstUsage, secondUsage, secondUsageUnknown, outcome, firstValidation, secondValidation
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let version = try values.decode(Int.self, forKey: .schemaVersion)
            let required: Set<String> = ["schemaVersion", "scope", "correctionID", "taskID", "threadID", "turnID", "phase",
                                         "secondRequestClaimed", "firstUsage", "secondUsageUnknown"]
            let optional: Set<String> = ["secondUsage", "outcome"]
            let keys = try APICorrectionDiagnosticCoding.keys(decoder)
            let allowed = required.union(optional).union(version >= 2 ? ["firstValidation"] : [])
                .union(version == 3 ? ["secondValidation"] : [])
            guard (1...3).contains(version), required.isSubset(of: keys), keys.isSubset(of: allowed),
                  version != 2 || keys.contains("firstValidation"),
                  version != 3 || keys.contains("firstValidation") || keys.contains("secondValidation") else {
                throw APICorrectionDiagnosticCoding.invalid(decoder)
            }
            let validation = keys.contains("firstValidation") ? try values.decode(FirstValidation.self, forKey: .firstValidation) : nil
            let second = keys.contains("secondValidation") ? try values.decode(FirstValidation.self, forKey: .secondValidation) : nil
            guard version == 3 || validation?.schemaFailures.allSatisfy({ $0.location == nil }) != false else {
                throw APICorrectionDiagnosticCoding.invalid(decoder)
            }
            self.init(schemaVersion: version, scope: try values.decode(String.self, forKey: .scope),
                correctionID: try values.decode(UUID.self, forKey: .correctionID), taskID: try values.decode(String.self, forKey: .taskID),
                threadID: try values.decode(String.self, forKey: .threadID), turnID: try values.decode(String.self, forKey: .turnID),
                phase: try values.decode(String.self, forKey: .phase), secondRequestClaimed: try values.decode(Bool.self, forKey: .secondRequestClaimed),
                firstUsage: try values.decode(APIModelCorrectionUsage.self, forKey: .firstUsage),
                secondUsage: try values.decodeIfPresent(APIModelCorrectionUsage.self, forKey: .secondUsage),
                secondUsageUnknown: try values.decode(Bool.self, forKey: .secondUsageUnknown),
                outcome: try values.decodeIfPresent(Outcome.self, forKey: .outcome), firstValidation: validation, secondValidation: second)
            guard scope == "provider_attempt_accounting_not_native_execution",
                  ["first_received", "second_claimed", "finished"].contains(phase),
                  [taskID, threadID, turnID].allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }),
                  APIModelCorrectionAccounting.validUsage(firstUsage), secondUsage.map(APIModelCorrectionAccounting.validUsage) ?? true,
                  secondValidation == nil || (phase == "finished" && secondRequestClaimed) else {
                throw APICorrectionDiagnosticCoding.invalid(decoder)
            }
        }
    }
    let directory: URL

    private static func validUsage(_ usage: APIModelCorrectionUsage) -> Bool {
        (0...100_000_000).contains(usage.inputTokens) && (0...100_000_000).contains(usage.outputTokens)
            && usage.totalTokens == usage.inputTokens + usage.outputTokens
            && (0...usage.inputTokens).contains(usage.cachedInputTokens)
            && (0...usage.outputTokens).contains(usage.reasoningOutputTokens)
    }
    func begin(taskID: String, threadID: String, turnID: String, firstUsage: APIModelCorrectionUsage,
               firstValidation: FirstValidation? = nil) throws -> Ticket {
        guard Self.validUsage(firstUsage) else { throw Failure.unavailable }
        for id in [taskID, threadID, turnID] {
            guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw Failure.unavailable }
        }
        let ticket = Ticket(id: UUID(), taskID: taskID, threadID: threadID, turnID: turnID, firstUsage: firstUsage,
                            firstValidation: firstValidation)
        try publish(record(ticket, phase: "first_received", claimed: false, usage: nil, unknown: false, outcome: nil), ticket: ticket)
        return ticket
    }
    func claimed(_ ticket: Ticket) throws {
        try requireFirst(ticket)
        try publish(record(ticket, phase: "second_claimed", claimed: true, usage: nil, unknown: true, outcome: nil), ticket: ticket)
    }
    func finish(_ ticket: Ticket, claimed: Bool, usage: APIModelCorrectionUsage?, outcome: Outcome,
                secondValidation: FirstValidation? = nil) throws {
        try requireFirst(ticket)
        if claimed { try requireFirst(ticket, phase: "second_claimed", claimed: true) }
        guard usage.map(Self.validUsage) ?? true else { throw Failure.unavailable }
        try publish(record(ticket, phase: "finished", claimed: claimed, usage: usage, unknown: claimed && usage == nil,
            outcome: outcome, secondValidation: claimed ? secondValidation : nil), ticket: ticket)
    }
    private func record(_ ticket: Ticket, phase: String, claimed: Bool, usage: APIModelCorrectionUsage?, unknown: Bool,
                        outcome: Outcome?, secondValidation: FirstValidation? = nil) -> Record {
        let detailed = ticket.firstValidation?.schemaFailures.contains { $0.location != nil } == true || secondValidation != nil
        return .init(schemaVersion: detailed ? 3 : ticket.firstValidation == nil ? 1 : 2, scope: "provider_attempt_accounting_not_native_execution", correctionID: ticket.id, taskID: ticket.taskID, threadID: ticket.threadID, turnID: ticket.turnID,
              phase: phase, secondRequestClaimed: claimed, firstUsage: ticket.firstUsage,
              secondUsage: usage, secondUsageUnknown: unknown, outcome: outcome, firstValidation: ticket.firstValidation,
              secondValidation: secondValidation)
    }
    private struct Handles {
        let parent: Int32
        let directory: Int32
        let name: String
        let identity: stat
    }
    private func handles() throws -> Handles {
        // Foundation may rewrite /private/var to /var after creation. Physical
        // descriptor traversal, not that changing spelling, owns the directory.
        guard directory.isFileURL, directory.baseURL == nil, directory.path.hasPrefix("/"),
              directory.host == nil || directory.host == "" || directory.host == "localhost",
              directory.user == nil, directory.password == nil, directory.query == nil, directory.fragment == nil,
              directory.path.utf8.count <= 4_096 else { throw Failure.unavailable }
        let components = directory.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.count <= 64,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw Failure.unavailable }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.unavailable }
        do {
            for component in components.dropLast() {
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Failure.unavailable }
                close(parent); parent = next
            }
            let name = components.last!
            var descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0, errno == ENOENT {
                if mkdirat(parent, name, 0o700) == 0 {
                    guard fsync(parent) == 0 else { throw Failure.unavailable }
                } else if errno != EEXIST { throw Failure.unavailable }
                descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw Failure.unavailable }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o700 else {
                close(descriptor); throw Failure.unavailable
            }
            return Handles(parent: parent, directory: descriptor, name: name, identity: metadata)
        } catch { close(parent); throw error }
    }
    private func requireDirectory(_ handles: Handles) throws {
        var held = stat(), named = stat()
        guard fstat(handles.directory, &held) == 0, fstatat(handles.parent, handles.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == handles.identity.st_dev, held.st_ino == handles.identity.st_ino,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino,
              held.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
              held.st_uid == geteuid(), held.st_mode & 0o777 == 0o700 else { throw Failure.unavailable }
    }
    private func encoded(_ value: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    private func requireFirst(_ ticket: Ticket, phase: String = "first_received", claimed: Bool = false) throws {
        let h = try handles(); defer { close(h.directory); close(h.parent) }
        try requireDirectory(h)
        let name = ticket.id.uuidString.lowercased() + "." + phase + ".json"
        let fd = openat(h.directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }; defer { close(fd) }
        var before = stat(), named = stat()
        guard fstat(fd, &before) == 0, fstatat(h.directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == named.st_dev, before.st_ino == named.st_ino,
              before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o777 == 0o400, (1...2_048).contains(before.st_size) else { throw Failure.unavailable }
        var data = Data(count: 2_049)
        let count = try data.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0, errno == EINTR { continue }; guard n >= 0 else { throw Failure.unavailable }
                if n == 0 { return offset }; offset += n
            }
            return offset
        }
        data.count = count
        let expected = try encoded(record(ticket, phase: phase, claimed: claimed, usage: nil, unknown: claimed, outcome: nil))
        var after = stat(), current = stat()
        guard data == expected, count == before.st_size, fstat(fd, &after) == 0,
              fstatat(h.directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, after.st_dev == current.st_dev, after.st_ino == current.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              after.st_mode == before.st_mode, after.st_nlink == 1 else { throw Failure.unavailable }
        try requireDirectory(h)
    }
    private func publish(_ value: Record, ticket: Ticket) throws {
        let bytes = try encoded(value)
        guard bytes.count <= 2_048 else { throw Failure.unavailable }
        let h = try handles(); defer { close(h.directory); close(h.parent) }
        try requireDirectory(h)
        let temporary = ".correction-" + UUID().uuidString.lowercased() + ".tmp"
        let name = ticket.id.uuidString.lowercased() + "." + value.phase + ".json"
        let descriptor = openat(h.directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor); _ = unlinkat(h.directory, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.unavailable }; offset += count
            }
        }
        guard fchmod(descriptor, 0o400) == 0, fsync(descriptor) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else { throw Failure.unavailable }
        var readback = Data(count: bytes.count + 1)
        let readCount = try readback.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw Failure.unavailable }
                if count == 0 { return offset }; offset += count
            }
            return offset
        }
        readback.count = readCount
        guard readback == bytes else { throw Failure.unavailable }
        try requireDirectory(h)
        guard renameatx_np(h.directory, temporary, h.directory, name, UInt32(RENAME_EXCL)) == 0,
              fsync(h.directory) == 0 else { throw Failure.unavailable }
        var held = stat(), named = stat()
        guard fstat(descriptor, &held) == 0, fstatat(h.directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino, held.st_mode & S_IFMT == S_IFREG,
              held.st_nlink == 1, held.st_uid == geteuid(), held.st_mode & 0o777 == 0o400,
              held.st_size == bytes.count else { throw Failure.unavailable }
        try requireDirectory(h)
    }
}

/// Correction eligibility must not rely on Foundation's duplicate-key or
/// decimal-rounding behavior. This scanner grants no normal decode authority.
/// Argument strings are kept opaque; native schema validation remains exact.
private struct APICorrectionJSONScanner {
    enum Invalid: Error { case shape }
    let bytes: [UInt8]
    var index = 0
    var nodes = 0
    var rejection: APIModelCorrectionJSON.RejectionDiagnostic?
    mutating func rejected(_ reason: APIModelCorrectionJSON.RejectionDiagnostic.Reason, key: Data? = nil) -> Invalid {
        if rejection == nil { rejection = .init(reason: reason, keyCategory: APIModelCorrectionJSON.keyCategory(key)) }
        return .shape
    }
    static let integerKeys = Set(["prompt_tokens", "completion_tokens", "total_tokens", "cached_tokens",
        "reasoning_tokens", "input_tokens", "output_tokens", "index", "created"].map { Data($0.utf8) })
    mutating func parse() throws {
        guard bytes.count <= APIProviderHTTPClient.maximumResponseBytes else { throw rejected(.dataLimit) }
        try value(depth: 0, key: nil); whitespace()
        guard index == bytes.count else { throw rejected(.trailingContent) }
    }
    mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true
    }
    mutating func string(decoded: Bool) throws -> Data {
        let start = index
        guard consume(34) else { throw rejected(.stringSyntax) }
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 92 { guard index < bytes.count else { throw rejected(.stringSyntax) }; index += 1 }
            else if byte == 34 {
                guard decoded else { return Data() }
                let token = Data(bytes[start..<index])
                guard let text = try JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed]) as? String else { throw rejected(.stringSyntax) }
                return Data(text.utf8)
            }
        }
        throw rejected(.stringSyntax)
    }
    mutating func value(depth: Int, key: Data?) throws {
        nodes += 1; whitespace()
        guard depth <= 64, nodes <= 16_384, index < bytes.count else {
            throw rejected(depth > 64 ? .depthLimit : nodes > 16_384 ? .nodeLimit : .unexpectedEnd, key: key)
        }
        if consume(123) {
            var keys = Set<Data>(); whitespace()
            if consume(125) { return }
            repeat {
                whitespace(); let name = try string(decoded: true)
                guard keys.insert(name).inserted else { throw rejected(.duplicateKey, key: name) }; whitespace()
                guard consume(58) else { throw rejected(.objectSeparator, key: name) }
                try value(depth: depth + 1, key: name); whitespace()
                if consume(125) { return }
                guard consume(44) else { throw rejected(.objectSeparator, key: name) }
            } while true
        }
        if consume(91) {
            whitespace(); if consume(93) { return }
            repeat {
                try value(depth: depth + 1, key: nil); whitespace()
                if consume(93) { return }; guard consume(44) else { throw rejected(.arraySeparator, key: key) }
            } while true
        }
        if bytes[index] == 34 { _ = try string(decoded: false); return }
        for literal in [Array("true".utf8), Array("false".utf8), Array("null".utf8)] {
            if bytes[index...].starts(with: literal) { index += literal.count; return }
        }
        let start = index
        while index < bytes.count, [45, 43, 46, 69, 101].contains(bytes[index]) || (48...57).contains(bytes[index]) { index += 1 }
        guard start < index else { throw rejected(.valueSyntax, key: key) }
        // Only the envelope's created field is an integer timestamp. Provider
        // extensions can contain unrelated fractional created timing metadata.
        if let key, Self.integerKeys.contains(key), key != Data("created".utf8) || depth == 1 {
            let raw = bytes[start..<index]
            guard raw.count <= 16, raw.allSatisfy({ (48...57).contains($0) }) else {
                throw rejected(raw.count > 16 ? .integerLength : .integerLexeme, key: key)
            }
        }
    }
}
enum APIModelCorrectionJSON {
    struct RejectionDiagnostic: Codable, Equatable, Sendable {
        enum Reason: String, Codable, Equatable, Sendable {
            case dataLimit = "data_limit", foundationJSON = "foundation_json"
            case depthLimit = "depth_limit", nodeLimit = "node_limit", unexpectedEnd = "unexpected_end"
            case trailingContent = "trailing_content", duplicateKey = "duplicate_key"
            case integerLength = "integer_length", integerLexeme = "integer_lexeme", stringSyntax = "string_syntax"
            case objectSeparator = "object_separator", arraySeparator = "array_separator", valueSyntax = "value_syntax"
            case unknown
        }
        enum KeyCategory: String, Codable, Equatable, Sendable {
            case none, usageCounter = "usage_counter", choiceIndex = "choice_index", createdTimestamp = "created_timestamp", other
        }
        let reason: Reason
        let keyCategory: KeyCategory
    }
    fileprivate static func keyCategory(_ key: Data?) -> RejectionDiagnostic.KeyCategory {
        guard let key else { return .none }
        if key == Data("created".utf8) { return .createdTimestamp }
        if key == Data("index".utf8) { return .choiceIndex }
        if APICorrectionJSONScanner.integerKeys.contains(key) { return .usageCounter }
        return .other
    }
    /// A second diagnostic pass after the authoritative Boolean has rejected the
    /// data. This returns enums only and cannot admit a response or spend a retry.
    static func rejectionDiagnostic(_ data: Data) -> RejectionDiagnostic? {
        guard data.count <= APIProviderHTTPClient.maximumResponseBytes else { return .init(reason: .dataLimit, keyCategory: .none) }
        do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { return .init(reason: .foundationJSON, keyCategory: .none) }
        var scanner = APICorrectionJSONScanner(bytes: Array(data))
        do { try scanner.parse(); return nil }
        catch { return scanner.rejection ?? .init(reason: .unknown, keyCategory: .none) }
    }
    static func isUnambiguous(_ data: Data) -> Bool {
        do {
            guard data.count <= APIProviderHTTPClient.maximumResponseBytes else { return false }
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            var scanner = APICorrectionJSONScanner(bytes: Array(data)); try scanner.parse(); return true
        }
        catch { return false }
    }
}

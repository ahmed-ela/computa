import CoreFoundation
import CryptoKit
import Foundation

/// Validation only. Parsing an arm does not claim it, authorize a page read, or
/// create a lease. Integration must atomically claim the private arm before use.
enum ClaudeResponseStreamDiagnostic {
    static let directoryName = "ClaudeResponseStreamDiagnostics-v1"
    static let purpose = "claude_synthetic_response_metadata_v1"
    static let maximumArmBytes = 4_096
    static let maximumArmLifetime: TimeInterval = 600

    struct Context: Sendable, Equatable {
        let taskID: UUID
        let threadID: UUID
        let turnID: UUID
        let runtimeGeneration: UUID
        let preparationID: UUID
        let inferenceID: UUID
        let modelID: String
    }

    struct ValidatedArm: Sendable {
        let nonce: UUID
        let context: Context
        let expiresAt: Date
        let remainingLifetime: TimeInterval
        var expectedMarker: String { ClaudeResponseStreamDiagnostic.responseMarker(nonce: nonce) }
    }

    static func responseMarker(nonce: UUID) -> String {
        "CLAUDESTREAM" + nonce.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    static func syntheticUserText(nonce: UUID) -> String {
        "Computa response diagnostic. Reply with exactly \(responseMarker(nonce: nonce)). Do not use tools."
    }

    /// Only the exact first synthetic user request qualifies. Native policy,
    /// tool declarations and environment context remain in the ordinary request.
    /// The eventual lease must anchor expiry before file I/O using a monotonic
    /// clock; this pure validator does not extend or enforce a lease lifetime.
    static func validateArm(_ data: Data, context: Context, request: WebModelResponseCodec.Request,
                            isNewThread: Bool, isMaintenance: Bool, isFirstInference: Bool,
                            hasCorrectionTicket: Bool, now: Date = Date()) -> ValidatedArm? {
        guard !Task.isCancelled, isNewThread, !isMaintenance, isFirstInference, !hasCorrectionTicket,
              !data.isEmpty, data.count <= maximumArmBytes, APIModelCorrectionJSON.isUnambiguous(data),
              context.modelID == request.model,
              let selection = WebsiteModelCatalog.inferenceSelection(for: context.modelID),
              selection.provider == "claude", selection.choice != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "provider", "purpose", "nonce", "modelID", "expiresAt", "userPromptSHA256"],
              ClaudeStreamJSON.integer(object["schemaVersion"], in: 1...1) != nil,
              object["provider"] as? String == "claude", object["purpose"] as? String == purpose,
              object["modelID"] as? String == context.modelID,
              let nonceText = object["nonce"] as? String, let nonce = UUID(uuidString: nonceText),
              nonce.uuidString.lowercased() == nonceText,
              let expiryText = object["expiresAt"] as? String, expiryText.utf8.count == 24 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        guard let expiry = formatter.date(from: expiryText), formatter.string(from: expiry) == expiryText,
              expiry > now, expiry.timeIntervalSince(now) <= maximumArmLifetime else { return nil }
        let expected = syntheticUserText(nonce: nonce)
        let digest = SHA256.hash(data: Data(expected.utf8)).map { String(format: "%02x", $0) }.joined()
        guard object["userPromptSHA256"] as? String == digest,
              request.prompt.components(separatedBy: responseMarker(nonce: nonce)).count == 2,
              WebsiteSyntheticFirstRequest.matches(request, expectedUserText: expected) else { return nil }
        return ValidatedArm(nonce: nonce, context: context, expiresAt: expiry,
                            remainingLifetime: expiry.timeIntervalSince(now))
    }
}

/// Native one-shot permission to collect finite diagnostic metadata. It grants
/// no response admission, completion, replay or tool authority. Browser code
/// must separately prove ownership and exact outbound prompt matching.
final class ClaudeResponseStreamLease: @unchecked Sendable {
    @TaskLocal static var current: ClaudeResponseStreamLease?

    private let lock = NSLock()
    private let context: ClaudeResponseStreamDiagnostic.Context
    private let fileClaim: WebsitePrivateDiagnosticCapture.Claim
    private let deadline: ContinuousClock.Instant
    private let serverPromptSHA256: String
    private let serverPromptUTF8Bytes: Int
    let expectedMarker: String
    private var active = true
    private var claimedView: ObjectIdentifier?
    private var binding: (ownerToken: String, generation: UUID)?
    private var attemptedPublication = false

    private init(arm: ClaudeResponseStreamDiagnostic.ValidatedArm, claim: WebsitePrivateDiagnosticCapture.Claim,
                 deadline: ContinuousClock.Instant, prompt: String) {
        context = arm.context; fileClaim = claim; self.deadline = deadline; expectedMarker = arm.expectedMarker
        serverPromptSHA256 = Self.hash(prompt); serverPromptUTF8Bytes = prompt.utf8.count
    }

    var isCurrent: Bool { lock.withLock { currentLocked } }
    var remainingMilliseconds: Int {
        lock.withLock {
            guard currentLocked else { return 0 }
            let parts = (deadline - ContinuousClock.now).components
            return Int(max(0, min(60_000, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)))
        }
    }
    private var currentLocked: Bool { active && ContinuousClock.now < deadline }

    func matches(context: ClaudeResponseStreamDiagnostic.Context) -> Bool {
        lock.withLock { currentLocked && self.context == context }
    }
    func matchesPrompt(_ prompt: String) -> Bool {
        guard prompt.utf8.count == serverPromptUTF8Bytes else { return false }
        let fingerprint = Self.hash(prompt)
        return lock.withLock { currentLocked && fingerprint == serverPromptSHA256 }
    }
    func claim(view: ObjectIdentifier) -> Bool {
        lock.withLock {
            guard currentLocked, claimedView == nil else { return false }
            claimedView = view; return true
        }
    }
    func bind(view: ObjectIdentifier, ownerToken: String, generation: UUID) -> Bool {
        guard ownerToken.utf8.count == 36, UUID(uuidString: ownerToken) != nil else { return false }
        return lock.withLock {
            guard currentLocked, claimedView == view, binding == nil else { return false }
            binding = (ownerToken, generation); return true
        }
    }
    func matches(view: ObjectIdentifier, ownerToken: String, generation: UUID) -> Bool {
        lock.withLock { matchesLocked(view: view, ownerToken: ownerToken, generation: generation) }
    }
    private func matchesLocked(view: ObjectIdentifier, ownerToken: String, generation: UUID) -> Bool {
        currentLocked && claimedView == view && binding?.ownerToken == ownerToken && binding?.generation == generation
    }
    func revoke() { lock.withLock { active = false } }

    static func consume(directory: URL?, context: ClaudeResponseStreamDiagnostic.Context,
                        request: WebModelResponseCodec.Request, isNewThread: Bool, isMaintenance: Bool,
                        isFirstInference: Bool, hasCorrectionTicket: Bool, now: Date = Date()) -> ClaudeResponseStreamLease? {
        consume(directory: directory, context: context, request: request, isNewThread: isNewThread,
            isMaintenance: isMaintenance, isFirstInference: isFirstInference, hasCorrectionTicket: hasCorrectionTicket,
            now: now, beforeArmClaim: nil)
    }

    #if DEBUG
    static func consume(directory: URL?, context: ClaudeResponseStreamDiagnostic.Context,
                        request: WebModelResponseCodec.Request, isNewThread: Bool, isMaintenance: Bool,
                        isFirstInference: Bool, hasCorrectionTicket: Bool, now: Date,
                        beforeArmClaimForTesting: @escaping @Sendable () -> Void) -> ClaudeResponseStreamLease? {
        consume(directory: directory, context: context, request: request, isNewThread: isNewThread,
            isMaintenance: isMaintenance, isFirstInference: isFirstInference, hasCorrectionTicket: hasCorrectionTicket,
            now: now, beforeArmClaim: beforeArmClaimForTesting)
    }
    #endif

    private static func consume(directory: URL?, context: ClaudeResponseStreamDiagnostic.Context,
                                request: WebModelResponseCodec.Request, isNewThread: Bool, isMaintenance: Bool,
                                isFirstInference: Bool, hasCorrectionTicket: Bool, now: Date,
                                beforeArmClaim: (@Sendable () -> Void)?) -> ClaudeResponseStreamLease? {
        let started = ContinuousClock.now
        guard !Task.isCancelled, isNewThread, !isMaintenance, isFirstInference, !hasCorrectionTicket,
              let directory else { return nil }
        var arm: ClaudeResponseStreamDiagnostic.ValidatedArm?, deadline: ContinuousClock.Instant?
        guard let claim = WebsitePrivateDiagnosticCapture.claim(directory: directory, record: .claudeResponseMetadata,
            maximumArmBytes: ClaudeResponseStreamDiagnostic.maximumArmBytes,
            validate: { bytes in
                guard let value = ClaudeResponseStreamDiagnostic.validateArm(bytes, context: context, request: request,
                    isNewThread: isNewThread, isMaintenance: isMaintenance, isFirstInference: isFirstInference,
                    hasCorrectionTicket: hasCorrectionTicket, now: now) else { return false }
                arm = value; deadline = started + .seconds(value.remainingLifetime); return true
            }, isCurrent: { !Task.isCancelled && (deadline.map { ContinuousClock.now < $0 } ?? true) },
            beforeArmClaim: beforeArmClaim), let arm, let deadline, !Task.isCancelled,
              ContinuousClock.now < deadline else { return nil }
        return Self(arm: arm, claim: claim, deadline: deadline, prompt: request.prompt)
    }

    @discardableResult
    func persist(snapshot: ClaudeResponseStreamSnapshot, view: ObjectIdentifier, ownerToken: String, generation: UUID,
                 commitDeadline: ContinuousClock.Instant? = nil) -> Bool {
        persist(snapshot: snapshot, view: view, ownerToken: ownerToken, generation: generation, commitDeadline: commitDeadline,
                beforeRecordWrite: nil, beforeCommit: nil)
    }

    #if DEBUG
    func persist(snapshot: ClaudeResponseStreamSnapshot, view: ObjectIdentifier, ownerToken: String, generation: UUID,
                 commitDeadline: ContinuousClock.Instant? = nil, beforeRecordWriteForTesting: @escaping () -> Void) -> Bool {
        persist(snapshot: snapshot, view: view, ownerToken: ownerToken, generation: generation, commitDeadline: commitDeadline,
                beforeRecordWrite: beforeRecordWriteForTesting, beforeCommit: nil)
    }
    func persist(snapshot: ClaudeResponseStreamSnapshot, view: ObjectIdentifier, ownerToken: String, generation: UUID,
                 commitDeadline: ContinuousClock.Instant? = nil, beforeCommitForTesting: @escaping () -> Void) -> Bool {
        persist(snapshot: snapshot, view: view, ownerToken: ownerToken, generation: generation, commitDeadline: commitDeadline,
                beforeRecordWrite: nil, beforeCommit: beforeCommitForTesting)
    }
    #endif

    private func persist(snapshot: ClaudeResponseStreamSnapshot, view: ObjectIdentifier, ownerToken: String, generation: UUID,
                         commitDeadline: ContinuousClock.Instant?, beforeRecordWrite: (() -> Void)?, beforeCommit: (() -> Void)?) -> Bool {
        let publicationDeadline = min(deadline, commitDeadline ?? deadline)
        guard !Task.isCancelled, lock.withLock({
            guard ContinuousClock.now < publicationDeadline,
                  matchesLocked(view: view, ownerToken: ownerToken, generation: generation), !attemptedPublication else { return false }
            attemptedPublication = true; return true
        }), let finite = try? ClaudeResponseStreamSnapshot.parse(snapshot.encodedData),
              let diagnostic = try? JSONSerialization.jsonObject(with: finite.encodedData),
              let record = try? JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "purpose": ClaudeResponseStreamDiagnostic.purpose, "provider": "claude",
                "evidenceClass": "page_world_untrusted", "instrumented": true,
                "taskID": context.taskID.uuidString.lowercased(), "threadID": context.threadID.uuidString.lowercased(),
                "turnID": context.turnID.uuidString.lowercased(), "runtimeGeneration": context.runtimeGeneration.uuidString.lowercased(),
                "preparationID": context.preparationID.uuidString.lowercased(), "inferenceID": context.inferenceID.uuidString.lowercased(),
                "modelID": context.modelID, "sessionToken": ownerToken, "documentGeneration": generation.uuidString.lowercased(),
                "serverPromptSHA256": serverPromptSHA256, "serverPromptUTF8Bytes": serverPromptUTF8Bytes, "diagnostic": diagnostic,
              ], options: [.sortedKeys, .withoutEscapingSlashes]) else { return false }
        return WebsitePrivateDiagnosticCapture.publish(record, using: fileClaim,
            isCurrent: { !Task.isCancelled && self.isCurrent && ContinuousClock.now < publicationDeadline },
            beforeRecordWrite: beforeRecordWrite, beforeCommit: beforeCommit,
            commit: { rename in
                self.lock.withLock {
                    guard !Task.isCancelled, ContinuousClock.now < publicationDeadline,
                          self.matchesLocked(view: view, ownerToken: ownerToken, generation: generation) else { return false }
                    // Preparation, fsync and cleanup are outside this lock. Only
                    // this final check and exclusive rename serialize with revoke.
                    // A delayed timeout task cannot extend the caller's budget.
                    return rename()
                }
            })
    }

    private static func hash(_ prompt: String) -> String {
        SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Untrusted page-world metadata. This type deliberately exposes no response
/// text, completion predicate, model identity, ownership or tool-call authority.
struct ClaudeResponseStreamSnapshot: Sendable {
    enum Failure: Error { case invalid }
    // The observer reads <=64 KiB of response bytes. Serialized metadata can be
    // larger: malformed JSON event records do not consume its 48 KiB shape budget.
    static let maximumEncodedBytes = 80 * 1_024
    let encodedData: Data

    static func parse(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes,
              APIModelCorrectionJSON.isUnambiguous(data),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "scope", "phase", "terminalReason", "armed", "armUsed", "matchedCalls",
                "status", "mime", "route", "bytesRead", "eventCount", "markerPresent", "readPending", "readCalls",
                "lockReleased", "unterminatedEventDiscarded", "transitionCount", "transitionReason", "restore", "events"],
              ClaudeStreamJSON.integer(object["version"], in: 1...1) != nil,
              object["scope"] as? String == "passive_synthetic_response_metadata_only",
              ClaudeStreamJSON.member(object["phase"], ["dormant", "waiting", "awaiting_response", "observing", "terminal"]),
              object["terminalReason"] is NSNull || ClaudeStreamJSON.member(object["terminalReason"], terminalReasons),
              let armed = ClaudeStreamJSON.boolean(object["armed"]),
              let armUsed = ClaudeStreamJSON.boolean(object["armUsed"]), !armed || armUsed,
              let matched = ClaudeStreamJSON.integer(object["matchedCalls"], in: 0...1), matched == 0 || armed,
              object["status"] is NSNull || ClaudeStreamJSON.integer(object["status"], in: 0...599) != nil,
              object["mime"] is NSNull || ClaudeStreamJSON.member(object["mime"], ["text/event-stream", "application/json", "other"]),
              object["route"] is NSNull || validRoute(object["route"]),
              let bytes = ClaudeStreamJSON.integer(object["bytesRead"], in: 0...65_536),
              let count = ClaudeStreamJSON.integer(object["eventCount"], in: 0...128),
              let marker = ClaudeStreamJSON.boolean(object["markerPresent"]),
              let pending = ClaudeStreamJSON.boolean(object["readPending"]),
              let reads = ClaudeStreamJSON.integer(object["readCalls"], in: 0...513),
              let released = ClaudeStreamJSON.boolean(object["lockReleased"]),
              let discarded = ClaudeStreamJSON.boolean(object["unterminatedEventDiscarded"]),
              let transitions = ClaudeStreamJSON.integer(object["transitionCount"], in: 0...1),
              ClaudeStreamJSON.member(object["transitionReason"], ["none", "allowed_fresh_to_conversation", "unexpected_route"]),
              ClaudeStreamJSON.member(object["restore"], ["not_attempted", "restored", "superseded", "restore_failed"]),
              let events = object["events"] as? [[String: Any]], events.count <= 128,
              events.allSatisfy(validEvent),
              count == events.count || (object["terminalReason"] as? String == "metadata_limit" && count == events.count + 1)
        else { throw Failure.invalid }
        let terminal = object["phase"] as? String == "terminal"
        guard terminal == !(object["terminalReason"] is NSNull),
              terminal == (object["restore"] as? String != "not_attempted"),
              (transitions != 0 || object["transitionReason"] as? String != "allowed_fresh_to_conversation"),
              (transitions != 1 || object["transitionReason"] as? String != "none") else { throw Failure.invalid }
        if matched == 0 {
            guard object["status"] is NSNull, object["mime"] is NSNull, object["route"] is NSNull,
                  bytes == 0, count == 0, !marker, !pending, reads == 0, !released, !discarded else { throw Failure.invalid }
        } else {
            guard validRoute(object["route"]) else { throw Failure.invalid }
        }
        switch object["phase"] as? String {
        case "dormant": guard !armed, matched == 0 else { throw Failure.invalid }
        case "waiting": guard armed, matched == 0 else { throw Failure.invalid }
        case "awaiting_response": guard matched == 1, object["status"] is NSNull else { throw Failure.invalid }
        case "observing": guard matched == 1, !(object["status"] is NSNull),
            ClaudeStreamJSON.member(object["mime"], ["text/event-stream", "application/json"]) else { throw Failure.invalid }
        default: break
        }
        // Stop can return while a pending read settles. EOF and marker presence
        // never imply provider completion. A joined marker need not occur whole
        // in any one textFields entry, nor in a metadata-limit-discarded record.
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard encoded.count <= maximumEncodedBytes else { throw Failure.invalid }
        return Self(encodedData: encoded)
    }

    private static let terminalReasons: Set<String> = ["navigation", "context_changed", "event_limit", "metadata_limit",
        "response_shape", "unsupported_mime", "empty_body", "response_unavailable", "read_limit", "end_of_stream",
        "chunk_shape", "byte_limit", "stream_unavailable", "fetch_threw", "fetch_rejected", "promise_shape",
        "installation_failed", "invalid_arm", "expired", "stopped"]
    private static let eventNames: Set<String> = ["message_start", "message_delta", "message_stop", "content_block_start",
        "content_block_delta", "content_block_stop", "ping", "error", "completion", "message", "done", "metadata", "chunk",
        "token", "conversation_delta", "stream_start", "stream_end", "text_delta", "message_limit", "json", "other"]
    private static let typeNames: Set<String> = ["message_start", "message_delta", "message_stop", "content_block_start",
        "content_block_delta", "content_block_stop", "text_delta", "text", "completion", "thinking", "thinking_delta",
        "signature_delta", "redacted_thinking", "tool_use", "input_json_delta", "error", "ping"]
    private static let safeKeys: Set<String> = ["type", "index", "content", "content_block", "delta", "text", "completion",
        "message", "usage", "input_tokens", "output_tokens", "stop_reason", "stop_sequence", "role", "id", "uuid",
        "model", "error", "events", "data", "chat_messages", "conversation_uuid"]
    private static let routeSegments: Set<String> = ["", "api", "organizations", "chat_conversations", "completion",
        "completions", "messages", "message", "conversation", "conversations", "stream", "chat", "v1", "v2",
        ":uuid", ":number", ":segment"]

    private static func validRoute(_ value: Any?) -> Bool {
        guard let path = value as? String, path.hasPrefix("/"), path.utf8.count <= 512 else { return false }
        let segments = path.components(separatedBy: "/")
        return segments.count <= 17 && segments.allSatisfy(routeSegments.contains)
    }

    private static func validEvent(_ event: [String: Any]) -> Bool {
        guard Set(event.keys) == ["name", "json", "type", "shape", "otherKeys", "sensitiveBranchesOmitted", "textFields"],
              ClaudeStreamJSON.member(event["name"], eventNames), let json = ClaudeStreamJSON.boolean(event["json"]),
              event["type"] is NSNull || ClaudeStreamJSON.member(event["type"], typeNames),
              let shapes = event["shape"] as? [[String: Any]], shapes.count <= 63,
              let texts = event["textFields"] as? [[String: Any]], texts.count <= 33,
              let other = ClaudeStreamJSON.integer(event["otherKeys"], in: 0...1_024),
              let sensitive = ClaudeStreamJSON.integer(event["sensitiveBranchesOmitted"], in: 0...1_024)
        else { return false }
        // The frozen observer caps object shapes at 32 but also records an array
        // shape per visited node. Its absolute bound is 32 + 31 array records.
        for shape in shapes {
            guard Set(shape.keys) == ["path", "kind"], validPath(shape["path"]),
                  ClaudeStreamJSON.member(shape["kind"], ["null", "array", "object", "string", "number", "boolean"]) else { return false }
        }
        for text in texts {
            guard Set(text.keys) == ["path", "utf16Length", "expectedMarkerPresent"],
                  let path = text["path"] as? String, validPath(path),
                  (path == "completion" || path == "text" || path.hasSuffix(".text")),
                  ClaudeStreamJSON.integer(text["utf16Length"], in: 0...65_536) != nil,
                  ClaudeStreamJSON.boolean(text["expectedMarkerPresent"]) != nil else { return false }
        }
        return json || (event["type"] is NSNull && shapes.isEmpty && texts.isEmpty && other == 0 && sensitive == 0)
    }

    /// Paths contain only fixed key names and anonymous array steps, never raw
    /// object keys, array indices, identifiers or response text.
    private static func validPath(_ value: Any?) -> Bool {
        guard let path = value as? String, !path.isEmpty, path.utf8.count <= 160 else { return false }
        if path == "$" { return true }
        var rest = path[...], depth = 0
        while !rest.isEmpty {
            if rest.hasPrefix("[]") {
                rest.removeFirst(2)
            } else {
                if depth > 0 {
                    guard rest.first == "." else { return false }
                    rest.removeFirst()
                }
                let key = rest.prefix { $0 != "." && $0 != "[" }
                guard safeKeys.contains(String(key)) else { return false }
                rest.removeFirst(key.count)
            }
            depth += 1
            guard depth <= 4 else { return false }
        }
        return true
    }
}

private enum ClaudeStreamJSON {
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    static func integer(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else { return nil }
        return number.intValue
    }
    static func member(_ value: Any?, _ values: Set<String>) -> Bool {
        (value as? String).map(values.contains) == true
    }
}

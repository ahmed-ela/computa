import CoreFoundation
import CryptoKit
import Foundation

/// One native submission's bounded main-world observation. A receipt permits
/// another full inspection; it cannot itself publish a response or tool call.
@MainActor
final class ChatGPTResponseCompletion {
    static let maximumTextUTF8Bytes = 220_000
    static let maximumInputUTF8Bytes = 180_000
    static let maximumSequence = 16

    enum DiagnosticReason: String, CaseIterable {
        case runtimeUnsupported = "runtime_unsupported", callLimit = "call_limit", decoderLimit = "decoder_limit"
        case runtimeResourcesUnavailable = "runtime_resources_unavailable", runtimeImportFailed = "runtime_import_failed"
        case runtimeCacheUnsupported = "runtime_cache_unsupported", runtimeIdentityChanged = "runtime_identity_changed"
        case runtimeCacheShape = "runtime_cache_shape", runtimeCacheEmpty = "runtime_cache_empty", runtimeCacheLimit = "runtime_cache_limit"
        case runtimeGetterUnavailable = "runtime_getter_unavailable", runtimeGetterFailed = "runtime_getter_failed"
        case runtimeMethodUnsupported = "runtime_method_unsupported", runtimeDecoderAmbiguous = "runtime_decoder_ambiguous"
        case routeChanged = "route_changed", wrapperChanged = "wrapper_changed"
        case inputShape = "input_shape", inputHash = "input_hash", ownerConflict = "owner_conflict"
        case parentChanged = "parent_changed", parentLimit = "parent_limit", ancestryMissing = "ancestry_missing"
        case finalStatus = "final_status", finalChanged = "final_changed", terminalOrder = "terminal_order", terminalOpaque = "terminal_opaque"
        case error, sendChanged = "send_changed", expired, observerException = "observer_exception"
    }

    struct Diagnostic: Equatable {
        let correlationID: UUID
        let sequence: Int
        let inputSHA256: String
        let reason: DiagnosticReason
        let calls: Int
        let instances: Int
    }

    struct Receipt: Equatable {
        let identity: UUID
        let revision: UInt64
        let correlationID: UUID
        let sequence: Int
        let inputSHA256: String
        let inputMessageID: String
        let conversationID: String
        let assistantMessageID: String
        let text: String
        let textSHA256: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.identity == rhs.identity && lhs.revision == rhs.revision
                && lhs.correlationID == rhs.correlationID && lhs.sequence == rhs.sequence
                && lhs.inputSHA256 == rhs.inputSHA256 && lhs.inputMessageID == rhs.inputMessageID
                && lhs.conversationID == rhs.conversationID && lhs.assistantMessageID == rhs.assistantMessageID
                && lhs.textSHA256 == rhs.textSHA256 && lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }
    }

    enum StreamFailureReason: String, Equatable { case emptyStream = "empty_stream", providerError = "provider_error" }

    struct FailureReceipt: Equatable {
        let identity: UUID
        let revision: UInt64
        let inputMessageID: String
        let conversationID: String
        let reason: StreamFailureReason
        let calls: Int
        let assistantMessages: Int
        let messageTerminalCount: Int
        let mainTerminalCount: Int
    }

    let correlationID: UUID
    let view: ObjectIdentifier
    let ownerToken: String
    let generation: UUID
    let sequence: Int
    let inputSHA256: String
    let inputUTF8Bytes: Int
    let deadline: ContinuousClock.Instant
    private(set) var revision: UInt64 = 0
    private(set) var invalidated = false
    private var terminal: Receipt?
    private var terminalFailure: FailureReceipt?

    init?(view: ObjectIdentifier, ownerToken: String, generation: UUID, sequence: Int,
          inputSHA256: String, inputUTF8Bytes: Int, deadline: ContinuousClock.Instant,
          correlationID: UUID = UUID()) {
        guard UUID(uuidString: ownerToken) != nil, (1...Self.maximumSequence).contains(sequence),
              Self.validSHA256(inputSHA256), (1...Self.maximumInputUTF8Bytes).contains(inputUTF8Bytes),
              !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
        self.view = view; self.ownerToken = ownerToken; self.generation = generation
        self.sequence = sequence; self.inputSHA256 = inputSHA256; self.inputUTF8Bytes = inputUTF8Bytes
        self.deadline = deadline; self.correlationID = correlationID
    }

    func isCurrent(view: ObjectIdentifier, ownerToken: String, generation: UUID, sequence: Int,
                   now: ContinuousClock.Instant = .now) -> Bool {
        !invalidated && !Task.isCancelled && now < deadline && self.view == view
            && self.ownerToken == ownerToken && self.generation == generation && self.sequence == sequence
    }

    func receipt(view: ObjectIdentifier, ownerToken: String, generation: UUID, sequence: Int,
                 now: ContinuousClock.Instant = .now) -> Receipt? {
        guard isCurrent(view: view, ownerToken: ownerToken, generation: generation, sequence: sequence, now: now) else { return nil }
        return terminal
    }

    func failureReceipt(view: ObjectIdentifier, ownerToken: String, generation: UUID, sequence: Int,
                        now: ContinuousClock.Instant = .now) -> FailureReceipt? {
        guard isCurrent(view: view, ownerToken: ownerToken, generation: generation, sequence: sequence, now: now) else { return nil }
        return terminalFailure
    }

    /// The first observed rejection may concern an unclaimed decoder, rather
    /// than the eventual matching input. Parsing it never changes authority,
    /// receipt identity, revocation or the original deadline, even after expiry.
    func diagnostic(_ raw: Any) -> Diagnostic? {
        guard let body = raw as? [String: Any],
              Set(body.keys) == ["version", "kind", "correlationID", "sequence", "inputSHA256", "reason", "calls", "instances"],
              Self.exactInteger(body["version"]) == 1, body["kind"] as? String == "diagnostic",
              let correlation = Self.canonicalUUID(body["correlationID"]), correlation == correlationID,
              Self.exactInteger(body["sequence"]) == sequence,
              body["inputSHA256"] as? String == inputSHA256,
              let reasonText = body["reason"] as? String, let reason = DiagnosticReason(rawValue: reasonText),
              let calls = Self.exactInteger(body["calls"]), (0...257).contains(calls),
              let instances = Self.exactInteger(body["instances"]), (0...4).contains(instances) else { return nil }
        return Diagnostic(correlationID: correlation, sequence: sequence, inputSHA256: inputSHA256,
                          reason: reason, calls: calls, instances: instances)
    }

    /// Foreign identities cannot revoke a current round. Once a matching
    /// observation is malformed, conflicting or explicitly invalidated, that
    /// round cannot be requalified by a later terminal callback.
    @discardableResult
    func receive(_ raw: Any, now: ContinuousClock.Instant = .now) -> Bool {
        guard !invalidated, !Task.isCancelled, now < deadline, let body = raw as? [String: Any],
              let correlation = Self.canonicalUUID(body["correlationID"]), correlation == correlationID,
              Self.exactInteger(body["sequence"]) == sequence,
              body["inputSHA256"] as? String == inputSHA256 else { return false }
        let identityKeys: Set<String> = ["version", "kind", "correlationID", "sequence", "inputSHA256"]
        guard Self.exactInteger(body["version"]) == 1, let kind = body["kind"] as? String else { return invalidate() }
        if kind == "invalidated" {
            guard Set(body.keys) == identityKeys else { return invalidate() }
            return invalidate()
        }
        if kind == "terminal_failure" {
            guard Set(body.keys) == identityKeys.union(["inputMessageID", "conversationID", "reason", "calls",
                "assistantMessages", "messageTerminalCount", "mainTerminalCount"]), terminal == nil,
                  let input = Self.canonicalUUID(body["inputMessageID"]), let conversation = Self.canonicalUUID(body["conversationID"]),
                  let rawReason = body["reason"] as? String, let reason = StreamFailureReason(rawValue: rawReason),
                  let calls = Self.exactInteger(body["calls"]), (3...256).contains(calls),
                  calls >= (reason == .providerError ? 4 : 3),
                  let assistants = Self.exactInteger(body["assistantMessages"]),
                  (0...calls - (reason == .providerError ? 4 : 3)).contains(assistants),
                  Self.exactInteger(body["messageTerminalCount"]) == 1,
                  let main = Self.exactInteger(body["mainTerminalCount"]), main == 1 else { return invalidate() }
            if let terminalFailure {
                guard terminalFailure.inputMessageID == input.uuidString.lowercased(),
                      terminalFailure.conversationID == conversation.uuidString.lowercased(), terminalFailure.reason == reason,
                      terminalFailure.calls == calls, terminalFailure.assistantMessages == assistants,
                      terminalFailure.messageTerminalCount == 1, terminalFailure.mainTerminalCount == main else { return invalidate() }
                return false
            }
            revision += 1
            terminalFailure = FailureReceipt(identity: UUID(), revision: revision, inputMessageID: input.uuidString.lowercased(),
                conversationID: conversation.uuidString.lowercased(), reason: reason, calls: calls,
                assistantMessages: assistants, messageTerminalCount: 1, mainTerminalCount: main)
            return true
        }
        guard kind == "terminal", Set(body.keys) == identityKeys.union(["inputMessageID", "conversationID", "messageID", "text"]),
              terminalFailure == nil,
              let inputMessageID = Self.canonicalUUID(body["inputMessageID"]),
              let conversationID = Self.canonicalUUID(body["conversationID"]),
              let messageID = Self.canonicalUUID(body["messageID"]),
              inputMessageID != messageID,
              let text = body["text"] as? String, !text.isEmpty,
              text.utf16.count <= Self.maximumTextUTF8Bytes, text.utf8.count <= Self.maximumTextUTF8Bytes else {
            return invalidate()
        }
        if let terminal {
            guard terminal.inputMessageID == inputMessageID.uuidString.lowercased(),
                  terminal.conversationID == conversationID.uuidString.lowercased(),
                  terminal.assistantMessageID == messageID.uuidString.lowercased(),
                  terminal.text.utf8.elementsEqual(text.utf8) else { return invalidate() }
            return false
        }
        revision += 1
        terminal = Receipt(identity: UUID(), revision: revision, correlationID: correlationID, sequence: sequence,
            inputSHA256: inputSHA256, inputMessageID: inputMessageID.uuidString.lowercased(),
            conversationID: conversationID.uuidString.lowercased(), assistantMessageID: messageID.uuidString.lowercased(), text: text,
            textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
        return true
    }

    func revoke() { _ = invalidate() }

    private func invalidate() -> Bool {
        guard !invalidated else { return false }
        invalidated = true; terminal = nil; terminalFailure = nil; revision += 1
        return true
    }

    static func canonicalUUID(_ raw: Any?) -> UUID? {
        guard let text = raw as? String, text.utf8.count == 36, let value = UUID(uuidString: text),
              value.uuidString.lowercased() == text else { return nil }
        return value
    }

    static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func exactInteger(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 1_000_000,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }
}

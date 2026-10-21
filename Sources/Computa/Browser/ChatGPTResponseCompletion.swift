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
        guard kind == "terminal", Set(body.keys) == identityKeys.union(["inputMessageID", "conversationID", "messageID", "text"]),
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
        invalidated = true; terminal = nil; revision += 1
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

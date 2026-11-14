import CoreFoundation
import CryptoKit
import Foundation

/// Optional shadow measurement of a single synthetic Qwen marker. The server's
/// normal model, reply and durable deletion proofs are prerequisites to publication.
final class QwenMarkerWireLease: @unchecked Sendable {
    @TaskLocal static var current: QwenMarkerWireLease?
    static let directoryName = "QwenMarkerWireDiagnostics-v1"
    static let purpose = "qwen_synthetic_marker_wire_v1"
    static let labels = ["Qwen3.7-Plus", "Qwen3.8-Max"]

    static func marker(_ nonce: UUID) -> String { "QWENWIRE" + nonce.uuidString.replacingOccurrences(of: "-", with: "") }
    static func userText(_ nonce: UUID) -> String { "Return exactly \(marker(nonce)) and nothing else. Do not call any tools." }

    // Only terminal classifications emitted by the fixed observer. "ready"
    // describes preparation and can never stand in for a completed observation.
    private static let outcomes: Set<String> = [
        "wire_equal", "after_done", "answer_limit", "byte_limit", "catalog_accessor",
        "catalog_ambiguous", "catalog_mime", "catalog_missing", "catalog_not_seen", "catalog_path_unverified",
        "catalog_binding", "catalog_binding_scope", "catalog_open_changed", "catalog_send_changed", "catalog_held_changed",
        "catalog_send_unobserved", "catalog_not_done", "catalog_final_url", "catalog_non_200", "catalog_response_type",
        "catalog_pending", "catalog_request", "catalog_response", "catalog_reused", "catalog_shape",
        "catalog_size", "choice", "delta", "duplicate_key", "early_terminal",
        "empty", "event_limit", "fetch_rejected", "frame_limit", "http",
        "http_or_reader", "ids", "incomplete", "interrupted", "invalid_json",
        "invalid_unicode", "invalid_utf8", "json_limit", "key", "marker_mismatch",
        "metadata", "missing_created", "model", "more_phases", "native_proof",
        "no_owned_reader", "ownership", "reader", "repeated_arm", "request",
        "request_id", "response_model_unobserved", "retired", "role", "scalar",
        "scope", "second_created", "second_request", "selection", "shape",
        "sse", "stream_unavailable", "unrecognized", "wrong_capability",
    ]

    private struct Binding {
        let owner: UUID
        let document: UUID
        let firstFingerprint: String
    }
    private let file: WebsitePrivateDiagnosticCapture.Claim
    private let admission: WebModelStartAdmission
    private let deadline: ContinuousClock.Instant
    private let promptHash: String
    private let promptBytes: Int
    let expectedMarker: String
    private let lock = NSLock()
    private var active = true
    private var view: ObjectIdentifier?
    private var binding: Binding?
    private var outcome: String?

    private init(file: WebsitePrivateDiagnosticCapture.Claim, admission: WebModelStartAdmission, nonce: UUID,
                 deadline: ContinuousClock.Instant, prompt: String) {
        self.file = file; self.admission = admission; self.deadline = deadline
        expectedMarker = Self.marker(nonce); promptHash = Self.digest(prompt); promptBytes = prompt.utf8.count
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func canonicalUUID(_ text: String) -> Bool { UUID(uuidString: text)?.uuidString.lowercased() == text }
    private var currentLocked: Bool { active && ContinuousClock.now < deadline }
    var isCurrent: Bool { lock.withLock { currentLocked } }
    var remainingMilliseconds: Int {
        lock.withLock {
            guard currentLocked else { return 0 }
            let time = (deadline - ContinuousClock.now).components
            return Int(min(60_000, max(0, Double(time.seconds) * 1_000 + Double(time.attoseconds) / 1e15)))
        }
    }
    func matches(admission: WebModelStartAdmission) -> Bool { lock.withLock { currentLocked && admission == self.admission } }
    func matchesPrompt(_ prompt: String) -> Bool {
        guard prompt.utf8.count == promptBytes else { return false }
        let hash = Self.digest(prompt)
        return lock.withLock { currentLocked && hash == promptHash }
    }
    func claim(view: ObjectIdentifier) -> Bool {
        lock.withLock {
            guard currentLocked, self.view == nil else { return false }
            self.view = view; return true
        }
    }
    func bind(view: ObjectIdentifier, ownerToken: String, generation: UUID, outboundFingerprint: String) -> Bool {
        guard ownerToken.utf8.count == 36, let owner = UUID(uuidString: ownerToken),
              outboundFingerprint.utf8.count == 64,
              outboundFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        return lock.withLock {
            guard currentLocked, self.view == view, binding == nil else { return false }
            binding = Binding(owner: owner, document: generation, firstFingerprint: outboundFingerprint); return true
        }
    }
    private func matchesLocked(_ view: ObjectIdentifier, _ owner: String, _ generation: UUID) -> Bool {
        guard let binding else { return false }
        return currentLocked && self.view == view && binding.owner == UUID(uuidString: owner) && binding.document == generation
    }
    func matches(view: ObjectIdentifier, ownerToken: String, generation: UUID) -> Bool {
        lock.withLock { matchesLocked(view, ownerToken, generation) }
    }
    @discardableResult
    func stage(_ finite: String, view: ObjectIdentifier, ownerToken: String, generation: UUID) -> Bool {
        guard finite.utf8.count <= 48, Self.outcomes.contains(finite) else { return false }
        return lock.withLock {
            guard matchesLocked(view, ownerToken, generation), outcome == nil else { return false }
            outcome = finite; return true
        }
    }
    func revoke() { lock.withLock { active = false } }

    static func consume(directory: URL?, admission: WebModelStartAdmission, request: WebModelResponseCodec.Request,
                        isNewThread: Bool, isMaintenance: Bool, isFirstInference: Bool, hasCorrectionTicket: Bool,
                        now: Date = Date()) -> QwenMarkerWireLease? {
        let started = ContinuousClock.now
        guard !Task.isCancelled, isNewThread, !isMaintenance, isFirstInference, !hasCorrectionTicket,
              admission.provider == "qwen", request.model == admission.modelID,
              let choice = WebsiteModelCatalog.inferenceSelection(for: request.model)?.choice,
              choice.provider == "qwen", choice.key == choice.label, labels.contains(choice.label),
              [admission.taskID, admission.threadID, admission.turnID].allSatisfy(canonicalUUID), let directory else { return nil }
        var nonce: UUID?
        var deadline: ContinuousClock.Instant?
        guard let claim = WebsitePrivateDiagnosticCapture.claim(directory: directory, record: .qwenMarkerWire, maximumArmBytes: 4096,
            validate: { data in
                guard APIModelCorrectionJSON.isUnambiguous(data),
                      let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(fields.keys) == ["schemaVersion","provider","purpose","nonce","modelID","expiresAt","userPromptSHA256"],
                      let version = fields["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
                      ["i", "q"].contains(String(cString: version.objCType)), version.intValue == 1, version == 1,
                      fields["purpose"] as? String == purpose, fields["provider"] as? String == "qwen",
                      fields["modelID"] as? String == request.model,
                      let text = fields["nonce"] as? String, canonicalUUID(text), let uuid = UUID(uuidString: text),
                      let expiryText = fields["expiresAt"] as? String, expiryText.utf8.count == 24 else { return false }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let expected = userText(uuid)
                guard let expiry = formatter.date(from: expiryText), formatter.string(from: expiry) == expiryText,
                      expiry > now, expiry.timeIntervalSince(now) <= 600,
                      fields["userPromptSHA256"] as? String == digest(expected),
                      request.prompt.components(separatedBy: marker(uuid)).count == 2,
                      WebsiteSyntheticFirstRequest.matches(request, expectedUserText: expected) else { return false }
                nonce = uuid; deadline = started + .seconds(expiry.timeIntervalSince(now)); return true
            }, isCurrent: { !Task.isCancelled && (deadline.map { ContinuousClock.now < $0 } ?? false) }),
            let nonce, let deadline, ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
        return Self(file: claim, admission: admission, nonce: nonce, deadline: deadline, prompt: request.prompt)
    }

    /// Called only after ordinary response validation, the saved deletion and its
    /// matching release journal append. Losing this measurement never loses a reply.
    @discardableResult
    func publishAfterRelease(reply: WebModelResponseCodec.Reply, model: WebsiteModelEvidence.Identity,
                             generation: UUID, firstFingerprint: String, receipt: WebsiteSessionCleanupReceipt) -> Bool {
        let message: String
        switch reply {
        case .message(let text), .assistantMessage(let text, .finalAnswer): message = text
        default: return false
        }
        guard !Task.isCancelled, message.utf8.elementsEqual(expectedMarker.utf8),
              let choice = WebsiteModelCatalog.inferenceSelection(for: admission.modelID)?.choice,
              model.key == choice.key, model.label == choice.label,
              receipt.schemaVersion == 2, receipt.receiptSaved, receipt.outcome == .closed, receipt.reason == .deleted,
              receipt.trigger == .inference, receipt.route == .embedded, receipt.provider == .qwen,
              receipt.taskID == admission.taskID, receipt.threadID == admission.threadID, receipt.turnID == admission.turnID,
              receipt.modelID == admission.modelID, receipt.runtimeGeneration == admission.runtimeGeneration.uuidString.lowercased(),
              receipt.inferenceID == admission.inferenceID.uuidString.lowercased(),
              let owner = receipt.sessionToken, Self.canonicalUUID(owner),
              let finite: String = lock.withLock({
                  guard currentLocked, let binding, binding.owner.uuidString.lowercased() == owner, binding.document == generation,
                        binding.firstFingerprint == firstFingerprint else { return nil }
                  return outcome
              }) else { return false }
        let record: [String: Any] = ["schemaVersion":1, "purpose":Self.purpose, "stage":finite,
            "evidenceClass":"page_world_untrusted", "taskID":receipt.taskID, "threadID":admission.threadID, "turnID":admission.turnID,
            "inferenceID":admission.inferenceID.uuidString.lowercased(), "runtimeGeneration":receipt.runtimeGeneration,
            "preparationID":admission.preparationID.uuidString.lowercased(), "modelID":admission.modelID, "sessionToken":owner,
            "documentGeneration":generation.uuidString.lowercased(), "cleanupAttemptID":receipt.attemptID]
        guard let bytes = try? JSONSerialization.data(withJSONObject: record, options:[.sortedKeys]) else { return false }
        return WebsitePrivateDiagnosticCapture.publish(bytes, using:file, isCurrent:{ !Task.isCancelled && self.isCurrent },
            commit:{ rename in self.lock.withLock { !Task.isCancelled && self.currentLocked && rename() } })
    }
}

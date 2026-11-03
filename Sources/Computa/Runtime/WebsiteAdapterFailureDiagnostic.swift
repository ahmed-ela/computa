import CoreFoundation
import Dispatch
import Foundation

/// Finite structure from an already rejected adapter read. Neither the packet,
/// its native context nor a private arm grants response, model or replay authority.
enum WebsiteAdapterFailureDiagnostic {
    static let directoryName = "WebsiteAdapterFailureDiagnostics-v1"
    static let purpose = "synthetic_adapter_failure_structure_v1"
    // A dedicated opt-in for each exact selection. Past generic or sibling-model
    // arms cannot authorize publishing a new diagnostic.
    private static let qwenAuthoredPurposes = [
        WebsiteModelChoice(provider: "qwen", key: "Qwen3.8-Max", label: "Qwen3.8-Max").modelID: "synthetic_qwen_max_authored_source_v1",
        WebsiteModelChoice(provider: "qwen", key: "Qwen3.7-Plus", label: "Qwen3.7-Plus").modelID: "synthetic_qwen_plus_authored_source_v1"
    ]
    static let maximumArmBytes = 4_096
    static let maximumPacketBytes = 80 * 1_024
    static let maximumLifetime: TimeInterval = 600

    struct Context: Sendable, Equatable {
        let taskID: UUID, threadID: UUID, turnID: UUID
        let runtimeGeneration: UUID, preparationID: UUID, transportGeneration: UUID, inferenceID: UUID
        let provider: String, modelID: String

        init?(admission: WebModelStartAdmission) {
            guard ["kimi", "qwen", "deepseek"].contains(admission.provider),
                  let task = Self.canonicalID(admission.taskID), let thread = Self.canonicalID(admission.threadID),
                  let turn = Self.canonicalID(admission.turnID),
                  WebsiteModelCatalog.inferenceSelection(for: admission.modelID)?.provider == admission.provider else { return nil }
            taskID = task; threadID = thread; turnID = turn
            runtimeGeneration = admission.runtimeGeneration; preparationID = admission.preparationID
            transportGeneration = admission.transportGeneration; inferenceID = admission.inferenceID
            provider = admission.provider; modelID = admission.modelID
        }
        private static func canonicalID(_ value: String) -> UUID? {
            guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else { return nil }
            return id
        }
    }

    struct Packet: Sendable {
        let provider: String, trigger: String
        let data: Data
        fileprivate init(provider: String, trigger: String, data: Data) {
            self.provider = provider; self.trigger = trigger; self.data = data
        }
    }
    struct Arm: Sendable {
        let nonce: UUID, expiry: Date
    }
    struct Binding: Sendable {
        let sessionToken: UUID, documentGeneration: UUID
        let sequence: Int
        let previousFirstBodyBound: Bool, priorModelSelectionVerified: Bool
    }

    static let tags: Set<String> = ["div", "span", "p", "pre", "code", "header", "svg", "path", "button", "input", "textarea", "br", "ul", "ol", "li", "a", "section", "article", "other"]
    static let kimiCategories: Set<String> = ["content_box", "markdown", "markdown_container", "reasoning_flow", "reasoning_container", "reasoning_part", "segment_code", "highlighter", "code_header", "code_language", "json_literal", "other"]
    static let qwenCategories: Set<String> = ["user_container", "chunk_root", "user_paragraph", "other"]
    static let deepSeekCategories: Set<String> = ["final", "reasoning", "paragraph", "code_block", "code_header", "code_language", "code_label", "code_corner_left", "code_corner_right", "syntax_token", "other"]
    static let kimiTriggers: Set<String> = ["authored_source_markdown_count", "authored_source_markdown_visibility", "authored_source_markdown_scope", "authored_source_json_count", "authored_source_pre_shape", "authored_source_highlighter_shape", "authored_source_segment_scope", "authored_source_code_visibility", "authored_source_outside_content"]
    static let deepSeekPredicates: Set<String> = ["final_count", "final_visibility", "final_parent", "sibling_scope", "paragraph_shape", "fence_child_count", "header_shape", "header_labels", "corner_shape", "interactive_attribute", "literal_span_shape", "node_limit"]

    /// Always strips first, including unarmed/foreign/malformed packets. The
    /// remaining observation follows its existing validation unchanged.
    static func remove(from observed: inout [String: Any], provider: String, action: String) -> Packet? {
        let raw = observed.removeValue(forKey: "adapterFailureStructure")
        guard action == "inspect", let error = observed["error"] as? String,
              let detail = observed["detail"] as? String else { return nil }
        return sanitize(raw, provider: provider, error: error, detail: detail)
    }

    static func sanitize(_ raw: Any?, provider: String, error: String, detail: String) -> Packet? {
        guard let value = raw as? [String: Any], integer(value["version"], 1...1) == 1,
              value["provider"] as? String == provider, let trigger = value["trigger"] as? String else { return nil }
        let common: Set<String> = ["version", "provider", "trigger", "nodeLimitReached", "nodeCount", "tree"]
        let categories: Set<String>
        switch provider {
        case "kimi":
            guard error == "unsupported_response_format", detail == trigger, kimiTriggers.contains(trigger),
                  Set(value.keys) == common.union(["markdownCount", "markdownCountOverflow", "excludedReasoningCount", "excludedReasoningCountOverflow", "answerVisible", "boxVisible", "markdownCandidates"]),
                  count(value, "markdownCount", overflow: "markdownCountOverflow", cap: 33),
                  count(value, "excludedReasoningCount", overflow: "excludedReasoningCountOverflow", cap: 33),
                  boolean(value["answerVisible"]) != nil, boolean(value["boxVisible"]) != nil,
                  candidates(value["markdownCandidates"], categories: kimiCategories, kind: "excludedReasoning") else { return nil }
            categories = kimiCategories
        case "qwen":
            if error == "unsupported_response_format", detail == "authored_source", trigger == detail {
                guard Set(value.keys) == ["version", "provider", "trigger", "stage", "reason", "count"],
                      let stage = value["stage"] as? String, let reason = value["reason"] as? String,
                      let count = integer(value["count"], 0...2), reason == "count" || count == 0 else { return nil }
                switch stage {
                case "flow", "phase":
                    guard reason == "count" ? count == 2 : reason == (stage == "flow" ? "hidden" : "class") else { return nil }
                case "custom", "markdown", "paragraph", "span", "literal":
                    guard reason == "count" ? count != 1 : ["parent_hidden", "mixed_text", "tag", "class", "hidden"].contains(reason) else { return nil }
                case "literal_contents":
                    guard reason == "count", count > 0 else { return nil }
                case "outside":
                    guard ["scope", "node_limit"].contains(reason) else { return nil }
                default: return nil
                }
                guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
                return Packet(provider: provider, trigger: trigger, data: data)
            }
            guard error == "conversation_changed", detail == "first_user_message", trigger == "full_prompt_mismatch",
                  Set(value.keys) == common.union(["comparison", "directParagraphCount", "visibleDirectParagraphCount", "descendantParagraphCount", "visibleDescendantParagraphCount", "paragraphCountOverflow", "paragraphs"]),
                  comparison(value["comparison"]), let overflow = boolean(value["paragraphCountOverflow"]),
                  let direct = integer(value["directParagraphCount"], 0...33),
                  let visibleDirect = integer(value["visibleDirectParagraphCount"], 0...33),
                  let all = integer(value["descendantParagraphCount"], 0...33),
                  let visibleAll = integer(value["visibleDescendantParagraphCount"], 0...33),
                  visibleDirect <= direct, visibleAll <= all, direct <= all, visibleDirect <= visibleAll,
                  (!overflow || [direct, visibleDirect, all, visibleAll].contains(33)),
                  candidates(value["paragraphs"], categories: qwenCategories, kind: "direct") else { return nil }
            categories = qwenCategories
        case "deepseek":
            guard error == "unsupported_response_format", detail == "authored_source", trigger == detail,
                  Set(value.keys) == common.union(["predicate", "finalCount", "finalCountOverflow", "knownReasoningPresent", "knownReasoningExcluded", "knownChromePresent", "knownChromeTextExcluded"]),
                  let predicate = value["predicate"] as? String, deepSeekPredicates.contains(predicate),
                  count(value, "finalCount", overflow: "finalCountOverflow", cap: 257),
                  let present = boolean(value["knownReasoningPresent"]), let excluded = boolean(value["knownReasoningExcluded"]),
                  !excluded || present, boolean(value["knownChromePresent"]) != nil,
                  boolean(value["knownChromeTextExcluded"]) == true else { return nil }
            categories = deepSeekCategories
        default: return nil
        }
        guard boolean(value["nodeLimitReached"]) != nil,
              let nodes = integer(value["nodeCount"], 0...256),
              tree(value["tree"], count: Int(nodes), categories: categories),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              data.count <= maximumPacketBytes else { return nil }
        return Packet(provider: provider, trigger: trigger, data: data)
    }

    private static func candidates(_ raw: Any?, categories: Set<String>, kind: String) -> Bool {
        guard let values = raw as? [[String: Any]], values.count <= 16 else { return false }
        return values.allSatisfy { item in
            guard Set(item.keys) == [kind, "visible", "ancestry", "ancestryTruncated"],
                  boolean(item[kind]) != nil, boolean(item["visible"]) != nil,
                  boolean(item["ancestryTruncated"]) != nil,
                  let ancestry = item["ancestry"] as? [String], ancestry.count <= 4 else { return false }
            return ancestry.allSatisfy { categories.contains($0) }
        }
    }
    private static func tree(_ raw: Any?, count expectedCount: Int, categories: Set<String>) -> Bool {
        guard let nodes = raw as? [[String: Any]], nodes.count == expectedCount else { return false }
        var depths: [Int64] = []
        for (index, node) in nodes.enumerated() {
            guard Set(node.keys) == ["parent", "depth", "tag", "category", "unknownClassPresent", "visible", "interactive", "elementChildCount", "childCountOverflow", "reasoningExcluded"],
                  let parent = integer(node["parent"], -1...255), let depth = integer(node["depth"], 0...16),
                  let tag = node["tag"] as? String, tags.contains(tag),
                  let category = node["category"] as? String, categories.contains(category),
                  boolean(node["unknownClassPresent"]) != nil, boolean(node["visible"]) != nil,
                  boolean(node["interactive"]) != nil, boolean(node["reasoningExcluded"]) != nil,
                  count(node, "elementChildCount", overflow: "childCountOverflow", cap: 257) else { return false }
            if index == 0 { guard parent == -1, depth == 0 else { return false } }
            else {
                guard parent >= 0, parent < Int64(index), depth == depths[Int(parent)] + 1,
                      boolean(nodes[Int(parent)]["reasoningExcluded"]) == false else { return false }
            }
            depths.append(depth)
        }
        return true
    }
    private static func comparison(_ raw: Any?) -> Bool {
        guard let value = raw as? [String: Any],
              Set(value.keys) == ["comparisonComplete", "actualUTF16Length", "expectedUTF16Length", "actualUTF8Length", "expectedUTF8Length", "commonPrefixLength", "commonSuffixLength", "exactEqual", "lfDelta", "crDelta", "nbspDelta", "nfcEqual", "crlfEqual", "trimEqual", "mismatchCategory"],
              let complete = boolean(value["comparisonComplete"]), boolean(value["exactEqual"]) == false,
              let actual = integer(value["actualUTF16Length"], 0...180_201), let expected = integer(value["expectedUTF16Length"], 0...180_201),
              let actualBytes = integer(value["actualUTF8Length"], 0...540_601), let expectedBytes = integer(value["expectedUTF8Length"], 0...540_601),
              let prefix = integer(value["commonPrefixLength"], 0...180_200), let suffix = integer(value["commonSuffixLength"], 0...180_200),
              let lf = integer(value["lfDelta"], -180_200...180_200), let cr = integer(value["crDelta"], -180_200...180_200),
              let nbsp = integer(value["nbspDelta"], -180_200...180_200),
              let nfc = boolean(value["nfcEqual"]), let crlf = boolean(value["crlfEqual"]), let trim = boolean(value["trimEqual"]),
              let category = value["mismatchCategory"] as? String,
              ["prefix_only", "suffix_only", "internal", "line_endings_only", "whitespace_only", "other"].contains(category) else { return false }
        if complete { return actual <= 180_200 && expected <= 180_200 && actualBytes <= 540_600 && expectedBytes <= 540_600 && prefix + suffix <= min(actual, expected) }
        return actualBytes == 540_601 && expectedBytes == 540_601 && prefix == 0 && suffix == 0
            && lf == 0 && cr == 0 && nbsp == 0 && !nfc && !crlf && !trim && category == "other"
    }
    private static func count(_ value: [String: Any], _ key: String, overflow: String, cap: Int64) -> Bool {
        guard let number = integer(value[key], 0...cap), let exceeded = boolean(value[overflow]) else { return false }
        return !exceeded || number == cap
    }
    private static func integer(_ value: Any?, _ range: ClosedRange<Int64>) -> Int64? {
        guard let number = ComputerToolArgumentContract.exactInt64(value), range.contains(number) else { return nil }
        return number
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    fileprivate static func capturePurpose(for packet: Packet, context: Context, binding: Binding) -> String? {
        guard packet.provider == context.provider, binding.sequence == 1 else { return nil }
        guard packet.provider == "qwen", packet.trigger == "authored_source" else { return purpose }
        return binding.priorModelSelectionVerified ? qwenAuthoredPurposes[context.modelID] : nil
    }

    static func validateArm(_ data: Data, context: Context, now: Date, expectedPurpose: String = purpose) -> Arm? {
        guard !data.isEmpty, data.count <= maximumArmBytes, APIModelCorrectionJSON.isUnambiguous(data),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["schemaVersion", "purpose", "nonce", "taskID", "threadID", "turnID", "provider", "modelID", "expiresAt"],
              integer(value["schemaVersion"], 1...1) == 1, value["purpose"] as? String == expectedPurpose,
              value["taskID"] as? String == context.taskID.uuidString.lowercased(),
              value["threadID"] as? String == context.threadID.uuidString.lowercased(),
              value["turnID"] as? String == context.turnID.uuidString.lowercased(),
              value["provider"] as? String == context.provider, value["modelID"] as? String == context.modelID,
              let nonceText = value["nonce"] as? String, let nonce = UUID(uuidString: nonceText), nonce.uuidString.lowercased() == nonceText,
              let date = value["expiresAt"] as? String, date.utf8.count == 24,
              let expiry = formatter().date(from: date), formatter().string(from: expiry) == date,
              expiry > now, expiry.timeIntervalSince(now) <= maximumLifetime else { return nil }
        return Arm(nonce: nonce, expiry: expiry)
    }
    static func formatter() -> DateFormatter {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)
        value.isLenient = false; value.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; return value
    }
}

/// Only a bounded publication fence; no retained page, task-wide authority or
/// additional browser read. Cancellation/cleanup revoke before exclusive rename.
final class WebsiteAdapterFailurePublication: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var attempted = false
    private var deadline: ContinuousClock.Instant
    init(deadline: ContinuousClock.Instant) { self.deadline = deadline }
    func revoke() { lock.withLock { active = false } }
    private var isCurrent: Bool { lock.withLock { active && ContinuousClock.now < deadline } }

    func publish(directory: URL, context: WebsiteAdapterFailureDiagnostic.Context,
                 binding: WebsiteAdapterFailureDiagnostic.Binding, packet: WebsiteAdapterFailureDiagnostic.Packet,
                 error: String, detail: String, now: Date = Date(),
                 beforeArmClaim: (@Sendable () -> Void)? = nil,
                 beforeCommit: (() -> Void)? = nil,
                 commitEligibility: (@MainActor @Sendable () -> Bool)? = nil) -> Bool {
        let started = ContinuousClock.now
        guard let purpose = WebsiteAdapterFailureDiagnostic.capturePurpose(for: packet, context: context, binding: binding),
              lock.withLock({ guard active, !attempted, started < deadline else { return false }; attempted = true; return true }),
              let structure = try? JSONSerialization.jsonObject(with: packet.data),
              WebsiteAdapterFailureDiagnostic.sanitize(structure, provider: context.provider, error: error, detail: detail) != nil else { return false }
        var arm: WebsiteAdapterFailureDiagnostic.Arm?
        guard let claim = WebsitePrivateDiagnosticCapture.claim(directory: directory, record: .adapterFailureStructure,
            maximumArmBytes: WebsiteAdapterFailureDiagnostic.maximumArmBytes, validate: { bytes in
                guard let parsed = WebsiteAdapterFailureDiagnostic.validateArm(bytes, context: context, now: now, expectedPurpose: purpose) else { return false }
                arm = parsed
                self.lock.withLock {
                    self.deadline = min(self.deadline, started + .milliseconds(Int64(parsed.expiry.timeIntervalSince(now) * 1_000)))
                }
                return true
            }, isCurrent: { self.isCurrent }, beforeArmClaim: beforeArmClaim), let arm else { return false }
        let record: [String: Any] = [
            "schemaVersion": 1, "purpose": purpose,
            "nonce": arm.nonce.uuidString.lowercased(), "capturedAt": WebsiteAdapterFailureDiagnostic.formatter().string(from: now),
            "evidenceClass": "rejected_adapter_structure_only", "automaticReplay": false,
            "taskID": context.taskID.uuidString.lowercased(), "threadID": context.threadID.uuidString.lowercased(),
            "turnID": context.turnID.uuidString.lowercased(), "runtimeGeneration": context.runtimeGeneration.uuidString.lowercased(),
            "preparationID": context.preparationID.uuidString.lowercased(), "transportGeneration": context.transportGeneration.uuidString.lowercased(),
            "inferenceID": context.inferenceID.uuidString.lowercased(), "provider": context.provider, "modelID": context.modelID,
            "sessionToken": binding.sessionToken.uuidString.lowercased(), "documentGeneration": binding.documentGeneration.uuidString.lowercased(),
            "sequence": binding.sequence, "submissionAcknowledged": true,
            "previousFirstBodyBound": binding.previousFirstBodyBound, "priorModelSelectionVerified": binding.priorModelSelectionVerified,
            "currentFirstBodyProofGranted": false, "responseAuthorityGranted": false,
            "error": error, "detail": detail, "structure": structure
        ]
        guard let bytes = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) else { return false }
        return WebsitePrivateDiagnosticCapture.publish(bytes, using: claim, isCurrent: { self.isCurrent },
            beforeCommit: beforeCommit, commit: { rename in
                if let commitEligibility { return self.commitOnMainActor(rename, eligibility: commitEligibility) }
                return self.lock.withLock {
                    guard self.active, ContinuousClock.now < self.deadline else { return false }
                    return rename()
                }
            })
    }

    private final class CommitResult: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Bool?
        func complete(_ value: Bool) { lock.withLock { result = value }; semaphore.signal() }
        var value: Bool? { lock.withLock { result } }
    }

    /// Called only by detached file preparation. MainActor never waits for a
    /// filesystem write: it performs its final native check and exclusive rename
    /// together, without suspension, under the same lock used by revocation.
    private func commitOnMainActor(_ rename: @escaping @Sendable () -> Bool,
                                    eligibility: @escaping @MainActor @Sendable () -> Bool) -> Bool {
        let result = CommitResult()
        Task { @MainActor in
            let committed = self.lock.withLock {
                guard self.active, ContinuousClock.now < self.deadline, eligibility() else { return false }
                return rename()
            }
            result.complete(committed)
        }
        let remaining = lock.withLock { (deadline - ContinuousClock.now).components }
        let seconds = max(0, min(1, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18))
        if result.semaphore.wait(timeout: .now() + seconds) == .timedOut { revoke() }
        return result.value ?? false
    }
}

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

    /// Metadata from the existing initial composer rejection only. Strip even
    /// malformed/foreign siblings before ordinary error/response classification.
    static func removeComposerGuard(from observed: inout [String: Any], provider: String, action: String) -> Packet? {
        let raw = observed.removeValue(forKey: "composerGuardDiagnostic")
        guard provider == "kimi", action == "inspect", observed["error"] as? String == "composer_not_empty",
              observed["detail"] == nil else { return nil }
        return sanitizeComposerGuard(raw)
    }

    static func sanitizeComposerGuard(_ raw: Any?) -> Packet? {
        let counts = ["childCountCapped32", "paragraphCountCapped32", "brCountCapped32", "unsupportedShapeCountCapped32"]
        guard let value = raw as? [String: Any], Set(value.keys) == Set(counts + ["version", "provider", "trigger", "stage", "serializedClass"]),
              integer(value["version"], 1...1) == 1, value["provider"] as? String == "kimi",
              value["trigger"] as? String == "composer_not_empty", value["stage"] as? String == "initial_inspect",
              let kind = value["serializedClass"] as? String, ["empty", "whitespace_only", "nonwhitespace"].contains(kind),
              counts.allSatisfy({ integer(value[$0], 0...32) != nil }),
              let children = integer(value["childCountCapped32"], 0...32),
              let paragraphs = integer(value["paragraphCountCapped32"], 0...32),
              let breaks = integer(value["brCountCapped32"], 0...32), children >= paragraphs, breaks <= paragraphs,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count <= 512 else { return nil }
        return Packet(provider: "kimi", trigger: "composer_not_empty", data: data)
    }

    /// Native context joins are diagnostic attribution, never model, ownership,
    /// cleanup or execution proof. Missing/foreign context is explicit JSON null.
    static func composerGuardLog(_ packet: Packet, context: Context?, sessionToken: UUID,
                                 documentGeneration: UUID, sequence: Int) -> String? {
        guard sequence == 0, packet.provider == "kimi", packet.trigger == "composer_not_empty",
              let raw = try? JSONSerialization.jsonObject(with: packet.data), let safe = sanitizeComposerGuard(raw),
              let metadata = try? JSONSerialization.jsonObject(with: safe.data) else { return nil }
        let attribution: Any
        if let context, context.provider == "kimi" {
            attribution = ["taskID": context.taskID.uuidString.lowercased(), "threadID": context.threadID.uuidString.lowercased(),
                           "turnID": context.turnID.uuidString.lowercased(), "inferenceID": context.inferenceID.uuidString.lowercased(),
                           "runtimeGeneration": context.runtimeGeneration.uuidString.lowercased(),
                           "preparationID": context.preparationID.uuidString.lowercased()]
        } else { attribution = NSNull() }
        let record: [String: Any] = ["version": 1, "diagnosticOnly": true, "attribution": attribution,
            "sessionToken": sessionToken.uuidString.lowercased(), "documentGeneration": documentGeneration.uuidString.lowercased(),
            "sequence": sequence, "metadata": metadata]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), data.count <= 1_536 else { return nil }
        return String(data: data, encoding: .utf8)
    }

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
            if error == "document_changed", detail == "response_container", trigger == detail {
                guard Set(value.keys) == ["version", "provider", "trigger", "total", "displayed", "rootVisible",
                                          "dual", "multi", "smrm", "cmrm", "ancestorLimited", "relation", "idRelation", "containers",
                                          "firstBodyBound", "responseIdentityRetained"],
                      let total = integer(value["total"], 0...3), let displayed = integer(value["displayed"], 0...3),
                      displayed <= total, displayed != 1,
                      ["rootVisible", "dual", "multi", "smrm", "cmrm", "ancestorLimited", "firstBodyBound", "responseIdentityRetained"].allSatisfy({ boolean(value[$0]) != nil }),
                      let relation = value["relation"] as? String,
                      let idRelation = value["idRelation"] as? String, ["same_uuid", "different_uuid", "other"].contains(idRelation),
                      let rows = value["containers"] as? [[String: Any]], rows.count == min(Int(total), 2),
                      (total == 0 ? relation == "none" : total == 1 ? relation == "single" : ["siblings", "nested", "other"].contains(relation)) else { return nil }
                var visibleCount: Int64 = 0
                var uuidCount = 0
                for row in rows {
                    guard Set(row.keys) == ["visible", "id"], let visible = boolean(row["visible"]),
                          let id = row["id"] as? String, ["missing", "empty_prefix", "uuid", "other"].contains(id) else { return nil }
                    if visible { visibleCount += 1 }
                    if id == "uuid" { uuidCount += 1 }
                }
                guard visibleCount <= displayed, total == 3 || visibleCount == displayed,
                      (uuidCount == 2) == (idRelation != "other"),
                      total != 0 || ["smrm", "cmrm", "ancestorLimited"].allSatisfy({ boolean(value[$0]) == false }),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count <= 1_024 else { return nil }
                return Packet(provider: provider, trigger: trigger, data: data)
            }
            if error == "document_changed", detail == "response_container_multiple", trigger == detail {
                guard Set(value.keys) == ["version", "provider", "trigger", "total", "displayed", "emptyRootMode",
                                          "dual", "multi", "smrm", "cmrm", "ancestorLimited", "relation", "idRelation", "containers"],
                      let total = integer(value["total"], 2...3), let displayed = integer(value["displayed"], 0...3),
                      displayed <= total, let emptyRootMode = boolean(value["emptyRootMode"]), emptyRootMode || displayed != 1,
                      ["dual", "multi", "smrm", "cmrm", "ancestorLimited"].allSatisfy({ boolean(value[$0]) != nil }),
                      let relation = value["relation"] as? String, ["siblings", "nested", "other"].contains(relation),
                      let idRelation = value["idRelation"] as? String, ["same_uuid", "different_uuid", "other"].contains(idRelation),
                      let rows = value["containers"] as? [[String: Any]], rows.count == 2 else { return nil }
                var visibleCount: Int64 = 0
                var uuidCount = 0
                for row in rows {
                    guard Set(row.keys) == ["visible", "id", "loading", "phase", "footer", "limited"],
                          let visible = boolean(row["visible"]), boolean(row["limited"]) != nil,
                          let id = row["id"] as? String, ["missing", "empty_prefix", "uuid", "other"].contains(id),
                          ["loading", "phase", "footer"].allSatisfy({ integer(row[$0], 0...3) != nil }) else { return nil }
                    if visible { visibleCount += 1 }
                    if id == "uuid" { uuidCount += 1 }
                }
                guard visibleCount <= displayed, total != 2 || visibleCount == displayed,
                      (uuidCount == 2) == (idRelation != "other"),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count <= 1_024 else { return nil }
                return Packet(provider: provider, trigger: trigger, data: data)
            }
            if error == "unsupported_response_format", detail == "authored_source", trigger == detail {
                let hasPhaseSet = value["phaseSet"] != nil
                let hasRawSource = value["rawSource"] != nil
                let authoredKeys: Set<String> = ["version", "provider", "trigger", "stage", "reason", "count"]
                let expectedKeys = authoredKeys.union(hasPhaseSet ? ["phaseSet"] : []).union(hasRawSource ? ["rawSource"] : [])
                guard Set(value.keys) == expectedKeys,
                      let stage = value["stage"] as? String, let reason = value["reason"] as? String,
                      let count = integer(value["count"], 0...2), reason == "count" || ["span_limit", "phase_set"].contains(stage) || count == 0,
                      !hasPhaseSet || stage == "phase_set" && qwenPhaseSet(value["phaseSet"], reason: reason),
                      !hasRawSource || qwenRawSource(value["rawSource"]) else { return nil }
                switch stage {
                case "flow", "phase":
                    guard reason == "count" ? count == 2 : reason == (stage == "flow" ? "hidden" : "class") else { return nil }
                case "custom", "markdown", "paragraph", "span", "literal":
                    guard reason == "count" ? count != 1 : ["parent_hidden", "mixed_text", "tag", "class", "hidden"].contains(reason) else { return nil }
                case "phase_set":
                    guard count == 2, ["multiple_text_bearing", "one_text_others_empty", "all_empty", "media", "hidden", "other_content",
                                       "over_limit", "phase_count_limit", "child_count_limit", "node_visit_limit"].contains(reason) else { return nil }
                case "span_limit":
                    guard count == 2, ["escape", "bidi", "decorated", "other", "ordinary_prefix"].contains(reason) else { return nil }
                case "inline":
                    guard ["escape", "bidi", "decorated", "other", "escape_json"].contains(reason) else { return nil }
                case "literal_contents":
                    guard reason == "count", count > 0 else { return nil }
                case "outside":
                    guard ["scope", "node_limit"].contains(reason) else { return nil }
                case "code_candidate":
                    guard ["custom_shape", "markdown_shape", "phase_shape", "pre_shape", "header_wrapper",
                           "header_shape", "language", "actions_shape", "body_classes", "body_tag", "body_attributes",
                               "body_visibility", "body_id", "body_empty", "body_children",
                           "plain_code_tag", "plain_code_attributes", "plain_code_visibility", "plain_code_shape",
                               "editor_tag", "editor_class", "editor_attributes", "editor_visibility", "body_geometry", "control_label", "control_shape",
                           "control_decoration", "collapse_state", "missing_copy", "ancestor_limit",
                           "ancestor_visibility", "ancestor_root"].contains(reason) else { return nil }
                case "code_sample":
                    guard ["channel_missing", "channel_shape", "candidate_changed", "candidate_missing",
                           "ancestor_limit", "synchronous_mutation", "result_missing", "result_multiple",
                           "result_invalid", "result_fields", "write_count", "write_invalid", "write_type",
                           "write_invalid_type", "write_invalid_size", "write_invalid_api",
                           "write_invalid_exec", "write_invalid_click", "write_invalid_hooks",
                           "write_invalid_resolve", "root_boundary",
                           "write_size", "utf8_roundtrip"].contains(reason) else { return nil }
                default: return nil
                }
                guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                      data.count <= (hasRawSource ? 1_024 : 512) else { return nil }
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

    /// Ordinary failure logging is limited to the closed finite Qwen packet.
    /// Other providers' larger structure records remain opt-in only.
    static func qwenAuthoredLogFields(_ packet: Packet) -> String? {
        guard packet.provider == "qwen", packet.trigger == "authored_source", packet.data.count <= 1_024,
              let value = try? JSONSerialization.jsonObject(with: packet.data) as? [String: Any],
              packet.data.count <= (value["rawSource"] == nil ? 512 : 1_024),
              let checked = sanitize(value, provider: "qwen", error: "unsupported_response_format", detail: "authored_source"),
              checked.data == packet.data else { return nil }
        return String(data: packet.data, encoding: .utf8)
    }

    /// Only closed Qwen ownership-failure packets are eligible for ordinary logging.
    static func qwenResponseContainerLogFields(_ packet: Packet) -> String? {
        guard packet.provider == "qwen", ["response_container_multiple", "response_container"].contains(packet.trigger), packet.data.count <= 1_024,
              let value = try? JSONSerialization.jsonObject(with: packet.data),
              let checked = sanitize(value, provider: "qwen", error: "document_changed", detail: packet.trigger),
              checked.data == packet.data else { return nil }
        return String(data: packet.data, encoding: .utf8)
    }

    private static func qwenPhaseSet(_ raw: Any?, reason: String) -> Bool {
        guard let value = raw as? [String: Any],
              Set(value.keys) == ["matched", "matchedOverflow", "sampled", "visible", "textBearing", "textBearingVisiblePhase", "textEmpty",
                                  "textUnknown", "physicallyEmpty", "singleWrapper", "direct", "otherWrapper"],
              let matched = integer(value["matched"], 2...33), let overflow = boolean(value["matchedOverflow"]),
              !overflow || matched == 33, (reason == "phase_count_limit") == (matched > 3),
              let sampled = integer(value["sampled"], 2...16), sampled == min(matched, 16),
              let visible = integer(value["visible"], 0...16), visible <= sampled,
              let bearing = integer(value["textBearing"], 0...16), let empty = integer(value["textEmpty"], 0...16),
              let unknown = integer(value["textUnknown"], 0...16), bearing + empty + unknown == sampled,
              let bearingVisible = integer(value["textBearingVisiblePhase"], 0...16),
              bearingVisible <= min(visible, bearing), bearingVisible >= max(visible + bearing - sampled, 0),
              let physicallyEmpty = integer(value["physicallyEmpty"], 0...16), physicallyEmpty <= empty,
              let wrapper = integer(value["singleWrapper"], 0...16), let direct = integer(value["direct"], 0...16),
              let other = integer(value["otherWrapper"], 0...16), wrapper + direct + other == sampled else { return false }
        return true
    }

    /// Eligibility failure metadata describes a rejected read only. Partial
    /// answersSeen counts never claim a complete source or response authority.
    private static func qwenRawSource(_ raw: Any?) -> Bool {
        let stages: Set<String> = ["request", "target", "root", "conversation_nodes", "host_props", "element_tree",
            "element_tree_budget", "element_tree_depth", "element_tree_nodekind",
            "element_tree_array", "element_tree_elementshape", "element_tree_kind",
            "element_tree_props", "element_tree_message", "element_tree_editflags",
            "element_tree_children", "element_tree_message_set", "element_tree_nodekind_string",
            "element_tree_nodekind_number", "element_tree_nodekind_bigint", "element_tree_nodekind_symbol",
            "element_tree_nodekind_function", "element_tree_message_set_empty", "element_tree_message_set_multiple",
            "message_keys", "message_identity", "message_state", "message_mode", "message_legacy_content",
            "message_empty_fields", "message_extra", "message_meta", "message_display", "message_timestamp",
            "feature_keys", "feature_values", "usage_shape", "phase_list", "phase_keys", "phase_kind", "phase_state",
            "phase_role_read", "phase_role_null", "phase_role_value_user",
            "phase_role_value_system", "phase_role_value_developer", "phase_role_value_tool",
            "phase_role_value_function", "phase_role_value_empty", "phase_role_value_other_string",
            "phase_role_type_undefined", "phase_role_type_boolean", "phase_role_type_number",
            "phase_role_type_bigint", "phase_role_type_symbol", "phase_role_type_function",
            "phase_role_type_object", "phase_status_read", "phase_status_null",
            "phase_status_value_waiting_input", "phase_status_value_error", "phase_status_value_pause",
            "phase_status_value_empty", "phase_status_value_other_string", "phase_status_type_undefined",
            "phase_status_type_boolean", "phase_status_type_number", "phase_status_type_bigint",
            "phase_status_type_symbol", "phase_status_type_function", "phase_status_type_object",
            "phase_extra", "phase_tools", "phase_scalar", "answer_count", "answer_role", "answer_value",
            "renderer_input", "utf8", "source_stability"]
        guard let value = raw as? [String: Any],
              Set(value.keys) == ["version", "stage", "kind", "phaseCount", "phaseOverflow", "answersSeen"],
              integer(value["version"], 1...1) == 1,
              let stage = value["stage"] as? String, stages.contains(stage),
              let kind = value["kind"] as? String, ["guard", "exception"].contains(kind) else { return false }
        if stage.hasPrefix("phase_role_") || stage.hasPrefix("phase_status_") {
            guard let count = integer(value["phaseCount"], 1...32), boolean(value["phaseOverflow"]) == false else { return false }
            return integer(value["answersSeen"], 0...min(count, 2)) != nil
        }
        if stage.hasPrefix("element_tree_") {
            return value["phaseCount"] is NSNull && value["phaseOverflow"] is NSNull && value["answersSeen"] is NSNull
        }
        if value["phaseCount"] is NSNull {
            return value["phaseOverflow"] is NSNull && value["answersSeen"] is NSNull
        }
        guard let count = integer(value["phaseCount"], 0...33), let overflow = boolean(value["phaseOverflow"]),
              overflow == (count == 33) else { return false }
        return value["answersSeen"] is NSNull || integer(value["answersSeen"], 0...min(count, 2)) != nil
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

import Foundation
import CoreFoundation
import CryptoKit
import Security

/// Stateless protocol translation. Tool execution remains entirely in the native engine.
/// A reply is completely validated before an output_item.done can authorize a tool.
enum APIModelResponseCodec {
    enum ToolNaming: String, Codable, Sendable {
        case legacy = "legacy_index_v1"
        case semantic = "semantic_v2"
    }
    enum Failure: String, Error, LocalizedError, Sendable {
        case invalidRequest, unsupportedParameter, unsupportedModality, invalidTool, invalidArguments
        case invalidHistory, invalidResponse, incompleteResponse, modelMismatch, invalidReasoning
        var errorDescription: String? {
            switch self {
            case .invalidRequest: "The API inference request is invalid."
            case .unsupportedParameter: "The API adapter does not support a requested parameter."
            case .unsupportedModality: "The selected API model does not support this input attachment."
            case .invalidTool: "The API response used an unknown or unavailable tool."
            case .invalidArguments: "The API response contained invalid tool arguments. No tool from this response was executed."
            case .invalidHistory: "The API tool history is incomplete or inconsistent."
            case .invalidResponse: "The API provider returned an invalid response. No tool from this response was executed."
            case .incompleteResponse: "The API provider response was incomplete. No tool from this response was executed."
            case .modelMismatch: "The API response did not identify the requested model."
            case .invalidReasoning: "The saved API reasoning continuation could not be verified."
            }
        }
    }
    /// A fatal decoder guard identifier only; no provider values, counts, IDs,
    /// text, arguments, headers or response bytes enter this observation.
    struct InvalidResponseDiagnostic: Codable, Equatable, Sendable {
        enum Format: String, Codable, Sendable, CaseIterable {
            case chatJSON = "chat_json", chatSSE = "chat_sse", responsesJSON = "responses_json"
        }
        enum Guard: String, Codable, Sendable, CaseIterable {
            case jsonParse = "json_parse"
            case chatRootObject = "chat_root_object", chatChoiceEnvelope = "chat_choice_envelope"
            case chatChoiceIndex = "chat_choice_index", chatContentType = "chat_content_type"
            case chatUnsupportedMessageFields = "chat_unsupported_message_fields", chatCallsType = "chat_calls_type"
            case chatCallFinishConsistency = "chat_call_finish_consistency", chatReasoningType = "chat_reasoning_type"
            case chatRetainedReasoningType = "chat_retained_reasoning_type", chatEmptyOutput = "chat_empty_output"
            case sseUTF8 = "sse_utf8", sseAfterDone = "sse_after_done", sseChunkEnvelope = "sse_chunk_envelope"
            case sseChunkIdentity = "sse_chunk_identity", sseChoiceIndex = "sse_choice_index"
            case sseChoiceDelta = "sse_choice_delta", sseRole = "sse_role", sseContentType = "sse_content_type"
            case sseReasoningType = "sse_reasoning_type", sseToolIndex = "sse_tool_index"
            case sseRepeatedCallID = "sse_repeated_call_id", sseCallsType = "sse_calls_type"
            case responsesItemIdentity = "responses_item_identity", responsesMessage = "responses_message"
            case responsesSummary = "responses_summary", responsesEncryptedType = "responses_encrypted_type"
            case responsesItemType = "responses_item_type"
            case usageObject = "usage_object", usageInputTokens = "usage_input_tokens"
            case usageOutputTokens = "usage_output_tokens", usageTotalTokens = "usage_total_tokens"
            case usageTotalConsistency = "usage_total_consistency", usageOutputDetails = "usage_output_details"
            case usageReasoningTokens = "usage_reasoning_tokens", usageInputDetails = "usage_input_details"
            case usageCachedTokens = "usage_cached_tokens"
        }
        let format: Format
        let guardID: Guard
        var isConsistent: Bool {
            switch guardID {
            case .jsonParse: return true
            case .chatRootObject: return format == .chatJSON
            case .chatChoiceEnvelope, .chatChoiceIndex, .chatContentType, .chatUnsupportedMessageFields,
                 .chatCallsType, .chatCallFinishConsistency, .chatReasoningType, .chatRetainedReasoningType, .chatEmptyOutput:
                return format == .chatJSON || format == .chatSSE
            case .sseUTF8, .sseAfterDone, .sseChunkEnvelope, .sseChunkIdentity, .sseChoiceIndex, .sseChoiceDelta,
                 .sseRole, .sseContentType, .sseReasoningType, .sseToolIndex, .sseRepeatedCallID, .sseCallsType:
                return format == .chatSSE
            case .responsesItemIdentity, .responsesMessage, .responsesSummary, .responsesEncryptedType, .responsesItemType:
                return format == .responsesJSON
            case .usageObject, .usageInputTokens, .usageOutputTokens, .usageTotalTokens, .usageTotalConsistency,
                 .usageOutputDetails, .usageReasoningTokens, .usageInputDetails, .usageCachedTokens:
                return true
            }
        }
    }
    private typealias InvalidResponseObserver = (InvalidResponseDiagnostic.Guard) -> Void
    private static func invalidResponse(_ guardID: InvalidResponseDiagnostic.Guard,
                                        _ observe: InvalidResponseObserver?) -> Failure {
        observe?(guardID)
        return .invalidResponse
    }
    /// Preserve the exact Foundation parser/options. Only parser failure is
    /// reclassified; parsed nonobject/root-shape guards remain at their callers.
    private static func responseJSONValue(_ data: Data, observe: InvalidResponseObserver?) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw invalidResponse(.jsonParse, observe) }
    }
    /// Preserve the shared integer validator and its exact Failure. Only fatal
    /// response-field callers label the guard; request validation is untouched.
    private static func responseInteger(_ value: Any?, default fallback: Int, range: ClosedRange<Int>,
                                        guardID: InvalidResponseDiagnostic.Guard,
                                        observe: InvalidResponseObserver?) throws -> Int {
        do { return try integer(value, default: fallback, range: range) }
        catch {
            if error as? Failure == .invalidResponse { observe?(guardID) }
            throw error
        }
    }
    struct Tool: @unchecked Sendable {
        let name: String
        let namespace: String?
        let wireName: String
        let custom: Bool
        let schema: [String: Any]
        let description: String
        var identity: String { (namespace ?? "") + "\u{0}" + name }
    }
    struct Request: @unchecked Sendable {
        let localModelID: String
        let provider: APIProviderDefinition
        let model: APIModelDefinition
        let threadID: String
        let stream: Bool
        let body: Data
        let tools: [Tool]
        let toolNaming: ToolNaming
        let allowedTools: Set<String>
        let requiredTool: Bool
        let maximumCalls: Int
        let historyCallIDs: Set<String>
        let capsules: APIReasoningCapsules
        let responseConfiguration: [String: Any]
        var path: String { provider.wireAPI == .chatCompletions ? "chat/completions" : "responses" }
    }
    struct Reply: @unchecked Sendable {
        let response: [String: Any]
        /// These are real provider fragment boundaries, not synthetic tokenization.
        let textDeltas: [String]
        let argumentDeltas: [[String]]
        /// Finite source facts only; no additional text or reasoning is retained.
        let finalTextSource: FinalTextSource?
    }
    enum DecodeOutcome: Sendable {
        case reply(Reply)
        /// No native output, generated call IDs or reasoning capsule is published.
        /// Usage is present and exact; every non-argument gate has already passed.
        case argumentsRejected(APIModelCorrectionUsage, [ArgumentRejectionDetail])
    }
    enum SchemaConstraint: String, Codable, Equatable, Sendable {
        case schemaMismatch = "schema_mismatch", missingRequired = "missing_required"
        case typeMismatch = "type_mismatch", unexpectedFields = "unexpected_fields"
        case arrayBounds = "array_bounds"
    }
    enum SchemaPathPart: Equatable, Sendable { case property(String), items }
    struct ArgumentRejectionDetail: Sendable {
        let toolIndex: Int
        let wireName: String
        let constraint: SchemaConstraint
        let path: [SchemaPathPart]
    }
    struct FiniteSchemaFailure: Codable, Equatable, Sendable {
        let toolIndex: Int
        let constraint: SchemaConstraint
    }
    private struct SchemaViolation { let constraint: SchemaConstraint; let path: [SchemaPathPart] }
    /// Finite observations only. This callback cannot authorize correction or
    /// publish any call; all existing complete-envelope gates remain authoritative.
    struct ArgumentValidationDiagnostic: Codable, Equatable, Sendable {
        enum Reason: String, Codable, Equatable, Sendable {
            case oversized, invalidJSON = "invalid_json", nonObject = "non_object"
            case schemaMismatch = "schema_mismatch", multipleKinds = "multiple_kinds"
        }
        enum EnvelopeRejection: String, Codable, Equatable, Sendable {
            case errorPresent = "error_present", missingID = "missing_id", invalidID = "invalid_id"
            case objectKind = "object_kind", systemFingerprintType = "system_fingerprint_type"
            case createdNoninteger = "created_noninteger", createdOutOfRange = "created_out_of_range"
            case unknownShape = "unknown_shape"
        }
        let reason: Reason
        var envelopeRejection: EnvelopeRejection? = nil
        var jsonRejection: APIModelCorrectionJSON.RejectionDiagnostic? = nil
        var schemaFailures: [FiniteSchemaFailure]? = nil
        let callCount: Int
        let rejectedCount: Int
        let envelopeShapeValid: Bool
        let unambiguousJSON: Bool
        let streamShapeAndUsageValid: Bool
        let knownUsage: Bool
        let correctionEligible: Bool
    }
    static let correctiveFeedback = "Native validation rejected the preceding provider response because tool arguments did not match the offered JSON schemas. No call from that rejected response was executed. Produce a new response using only the unchanged offered tools and exact schema-valid arguments. Preserve the confirmed outcomes in the supplied history; do not repeat actions already completed in that history."

    static let schemaFeedbackMarker = "Trusted schema validation details (from the unchanged offered tools):\n"
    static func correctiveRequest(_ original: Request, rejectionDetails: [ArgumentRejectionDetail] = []) throws -> Request {
        guard original.provider.wireAPI == .chatCompletions,
              var body = try JSONSerialization.jsonObject(with: original.body) as? [String: Any],
              var messages = body["messages"] as? [[String: Any]], !messages.isEmpty else { throw Failure.invalidRequest }
        let suffix = trustedSchemaFeedback(original, details: rejectionDetails)
        // Optional detail never displaces the existing generic instruction or
        // changes the original request-size guard.
        let feedback = original.body.count + 2 * (correctiveFeedback.utf8.count + suffix.utf8.count) + 64 <= maximumText
            ? correctiveFeedback + suffix : correctiveFeedback
        if messages[0]["role"] as? String == "system" {
            guard let originalText = messages[0]["content"] as? String else { throw Failure.invalidRequest }
            messages[0]["content"] = originalText + "\n\n" + feedback
        } else {
            messages.insert(["role": "system", "content": feedback], at: 0)
        }
        body["messages"] = messages
        let bytes = try json(body)
        guard bytes.count <= maximumText else { throw Failure.invalidRequest }
        return Request(localModelID: original.localModelID, provider: original.provider, model: original.model,
                       threadID: original.threadID, stream: original.stream, body: bytes, tools: original.tools,
                       toolNaming: original.toolNaming, allowedTools: original.allowedTools, requiredTool: original.requiredTool,
                       maximumCalls: original.maximumCalls, historyCallIDs: original.historyCallIDs,
                       capsules: original.capsules, responseConfiguration: original.responseConfiguration)
    }

    private static func trustedSchemaFeedback(_ request: Request, details: [ArgumentRejectionDetail]) -> String {
        guard !details.isEmpty, details.count <= 8 else { return "" }
        var records: [[String: Any]] = []
        for detail in details.sorted(by: { $0.toolIndex < $1.toolIndex }) {
            guard request.tools.indices.contains(detail.toolIndex), detail.path.count <= 8 else { continue }
            let tool = request.tools[detail.toolIndex]
            guard detail.wireName == tool.wireName, request.allowedTools.contains(tool.wireName) else { continue }
            var schema = tool.schema, schemaPath: [String] = [], validPath = true
            for part in detail.path {
                switch part {
                case .property(let name):
                    guard name.utf8.count <= 128, let child = (schema["properties"] as? [String: [String: Any]])?[name] else { validPath = false; break }
                    schema = child; schemaPath += ["properties", name]
                case .items:
                    guard let child = schema["items"] as? [String: Any] else { validPath = false; break }
                    schema = child; schemaPath.append("items")
                }
                if !validPath { break }
            }
            // Uncertain localization falls back to a brief for the known tool;
            // no supplied path string is ever copied without schema resolution.
            if !validPath { schema = tool.schema; schemaPath = [] }
            var record: [String: Any] = ["tool_index": detail.toolIndex, "callable": tool.wireName,
                "constraint": validPath ? detail.constraint.rawValue : SchemaConstraint.schemaMismatch.rawValue,
                "schema_path": schemaPath]
            let types = (schema["type"] as? String).map { [$0] } ?? (schema["type"] as? [String]) ?? []
            if !types.isEmpty, types.count <= 7, types.allSatisfy({ ["object","array","string","number","integer","boolean","null"].contains($0) }) { record["expected_types"] = types.sorted() }
            if let required = schema["required"] as? [String], required.count <= 16, required.allSatisfy({ $0.utf8.count <= 128 }) { record["required_fields"] = required.sorted() }
            if let properties = schema["properties"] as? [String: Any], properties.count <= 16, properties.keys.allSatisfy({ $0.utf8.count <= 128 }) { record["declared_fields"] = properties.keys.sorted() }
            if strictBool(schema["additionalProperties"]) == false { record["additional_fields_allowed"] = false }
            if schema["enum"] != nil { record["follow_offered_enum"] = true }
            records.append(record)
        }
        guard !records.isEmpty, let bytes = try? json(records), bytes.count <= 1_536,
              let text = String(data: bytes, encoding: .utf8) else { return "" }
        return "\n\n" + schemaFeedbackMarker + text
    }

    struct TextShape: Codable, Equatable, Sendable {
        let utf8Bytes: Int
        let unicodeScalars: Int
        let hyphenMinusCount: Int
        let nonBreakingHyphenCount: Int
    }
    struct FinalTextSource: Sendable {
        let upstream: TextShape
        let decoded: TextShape
        let upstreamMatchesDecoded: Bool
    }
    struct FinalTextDiagnostic: Codable, Sendable {
        let kind: String
        let responseID: String
        let modelID: String
        let providerID: String
        let upstream: TextShape
        let decoded: TextShape
        let serialized: TextShape
        let upstreamMatchesDecoded: Bool
        let decodedMatchesSerialized: Bool
        let streamDeltasMatchSerialized: Bool?
        let completedMatchesSerialized: Bool?
    }
    private static let maximumText = 2_000_000

    enum HostProjectionPurpose: Equatable, Sendable {
        case ordinaryInference
        case nativeCompaction
    }

    /// Called only by the native server after current-turn admission. Appending
    /// to the translated provider body keeps engine history, tool declarations,
    /// capsules and echoed response configuration unchanged.
    static func appendingHostDeveloperMessage(_ text: String, to original: Request, userInputs: [String] = [],
                                             purpose: HostProjectionPurpose = .ordinaryInference) throws -> Request {
        guard !text.isEmpty, text.utf8.count <= 16_384,
              userInputs.count <= 1_024, userInputs.allSatisfy({ !$0.isEmpty }),
              userInputs.reduce(0, { $0 + $1.utf8.count }) <= maximumText,
              var body = try JSONSerialization.jsonObject(with: original.body) as? [String: Any] else { throw Failure.invalidRequest }
        if purpose == .nativeCompaction {
            guard original.tools.isEmpty, original.allowedTools.isEmpty, !original.requiredTool else { throw Failure.invalidRequest }
        }
        func removeMaintenanceTail(from items: inout [[String: Any]]) throws -> [String: Any]? {
            guard purpose == .nativeCompaction else { return nil }
            // Purpose comes from admitted native metadata, never this text.
            // Validate only the pinned engine's structural maintenance boundary
            // and keep its entire final message unchanged and last.
            guard let tail = items.last, (tail["type"] as? String ?? "message") == "message",
                  tail["role"] as? String == "user" else { throw Failure.invalidRequest }
            if let content = tail["content"] as? String {
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidRequest }
            } else if let content = tail["content"] as? [[String: Any]], !content.isEmpty {
                guard content.allSatisfy({ item in
                    guard let type = item["type"] as? String, ["text", "input_text"].contains(type),
                          let text = item["text"] as? String else { return false }
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) else { throw Failure.invalidRequest }
            } else { throw Failure.invalidRequest }
            return items.removeLast()
        }
        switch original.provider.wireAPI {
        case .chatCompletions:
            guard var messages = body["messages"] as? [[String: Any]] else { throw Failure.invalidRequest }
            let maintenance = try removeMaintenanceTail(from: &messages)
            // Preserve the provider's template after adding trusted host text.
            // Qwen requires its system instructions in one opening message;
            // merely mapping developer to system would create a late system
            // message and revive the provider's wrong_api_format rejection.
            let role = original.provider.isCerebrasInference && original.model.id == "qwen-3.8-27b" ? "system" : "developer"
            messages.append(["role": role, "content": text])
            messages += userInputs.map { ["role": "user", "content": $0] }
            if let maintenance { messages.append(maintenance) }
            body["messages"] = try chatTemplateMessages(messages,
                selection: .init(provider: original.provider, model: original.model))
        case .responses:
            var items: [[String: Any]]
            if let input = body["input"] as? String { items = [["role": "user", "content": input]] }
            else if let input = body["input"] as? [[String: Any]] { items = input }
            else { throw Failure.invalidRequest }
            let maintenance = try removeMaintenanceTail(from: &items)
            items.append(["type": "message", "role": "developer", "content": [["type": "input_text", "text": text]]])
            items += userInputs.map { ["type": "message", "role": "user", "content": [["type": "input_text", "text": $0]]] }
            if let maintenance { items.append(maintenance) }
            body["input"] = items
        }
        let bytes = try json(body)
        guard bytes.count <= maximumText else { throw Failure.invalidRequest }
        return Request(localModelID: original.localModelID, provider: original.provider, model: original.model,
            threadID: original.threadID, stream: original.stream, body: bytes, tools: original.tools,
            toolNaming: original.toolNaming, allowedTools: original.allowedTools, requiredTool: original.requiredTool,
            maximumCalls: original.maximumCalls, historyCallIDs: original.historyCallIDs,
            capsules: original.capsules, responseConfiguration: original.responseConfiguration)
    }

    static func prepare(_ data: Data, selection: APIProviderCatalog.Selection, threadID: String,
                        capsules: APIReasoningCapsules, toolNaming: ToolNaming = .legacy) throws -> Request {
        guard data.count <= maximumText, var raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let localID = raw["model"] as? String,
              APIProviderCatalog.identity(for: localID) == APIProviderCatalog.Identity(providerID: selection.provider.id, modelID: selection.model.id),
              UUID(uuidString: threadID) != nil else { throw Failure.invalidRequest }
        let known: Set<String> = ["model", "instructions", "input", "tools", "tool_choice", "parallel_tool_calls", "max_tool_calls", "reasoning", "store", "stream", "stream_options", "include", "service_tier", "prompt_cache_key", "text", "client_metadata", "metadata", "max_output_tokens", "temperature", "top_p", "previous_response_id", "truncation", "access_programs", "background", "safety_identifier"]
        guard Set(raw.keys).isSubset(of: known), absent(raw["previous_response_id"]), absent(raw["access_programs"]),
              absent(raw["truncation"]) || raw["truncation"] as? String == "disabled",
              absent(raw["service_tier"]) || raw["service_tier"] as? String == "auto" else { throw Failure.unsupportedParameter }
        let stream = try boolean(raw["stream"], default: false)
        guard !(try boolean(raw["store"], default: false)) else { throw Failure.unsupportedParameter }
        let parallel = try boolean(raw["parallel_tool_calls"], default: true)
        // A resumed thread may retain old Chrome specs. Keep that catalog only
        // to validate historical call/output pairs; never advertise it again.
        let historyTools = try parseTools(raw["tools"], naming: toolNaming)
        if let definitions = raw["tools"] as? [[String: Any]] {
            raw["tools"] = ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: localID)
        }
        // Removing an active tool must not renumber its neighbours: historical
        // calls and current declarations share one stable provider identity.
        let historyByIdentity = Dictionary(uniqueKeysWithValues: historyTools.map { ($0.identity, $0) })
        let tools = try parseTools(raw["tools"], naming: toolNaming).map { visible -> Tool in
            guard let original = historyByIdentity[visible.identity] else { throw Failure.invalidTool }
            return Tool(name: visible.name, namespace: visible.namespace, wireName: original.wireName,
                        custom: visible.custom, schema: visible.schema, description: visible.description)
        }
        var allowed = Set(tools.map(\.wireName)), required = false
        var wireChoice: Any = "auto"
        if let choice = raw["tool_choice"] as? String {
            guard ["auto", "none", "required"].contains(choice) else { throw Failure.unsupportedParameter }
            if choice == "none" { allowed = [] }; required = choice == "required"; wireChoice = choice
        } else if let choice = raw["tool_choice"] as? [String: Any] {
            guard ["function", "custom"].contains(choice["type"] as? String ?? ""),
                  let name = choice["name"] as? String,
                  let tool = tools.first(where: { $0.name == name && $0.namespace == choice["namespace"] as? String }),
                  tool.custom == (choice["type"] as? String == "custom") else { throw Failure.invalidTool }
            allowed = [tool.wireName]; required = true
            wireChoice = ["type": "function", "function": ["name": tool.wireName]]
        } else if !absent(raw["tool_choice"]) { throw Failure.invalidRequest }
        let limit = try integer(raw["max_tool_calls"], default: 64, range: 1...128)
        let maximumCalls = parallel ? limit : 1
        let configuration = try responseConfiguration(raw, parallel: parallel)
        let history = try messages(raw, tools: historyTools, selection: selection, threadID: threadID, capsules: capsules, toolNaming: toolNaming)
        var body: [String: Any]
        if selection.provider.wireAPI == .responses {
            body = raw
            body.removeValue(forKey: "client_metadata"); body.removeValue(forKey: "metadata")
            body.removeValue(forKey: "prompt_cache_key")
            body["model"] = selection.model.id; body["store"] = false
            body["input"] = try responseHistory(raw["input"], selection: selection, threadID: threadID, capsules: capsules)
            // Native Responses reasoning capsules belong to the remote provider; the chat
            // adapter's locally sealed continuation is never sent to a different wire API.
            body["stream"] = false
        } else {
            body = ["model": selection.model.id, "messages": history.messages, "stream": stream, "n": 1]
            if !tools.isEmpty {
                body["tools"] = try tools.map { ["type": "function", "function": ["name": $0.wireName, "description": try chatCompletionToolDescription($0), "parameters": $0.schema]] as [String: Any] }
                body["tool_choice"] = wireChoice
                body["parallel_tool_calls"] = parallel
            } else if required { throw Failure.invalidTool }
            if stream { body["stream_options"] = ["include_usage": true] }
            if let reasoning = raw["reasoning"] as? [String: Any], let effort = reasoning["effort"] as? String {
                guard ["none", "minimal", "low", "medium", "high", "xhigh"].contains(effort) else { throw Failure.unsupportedParameter }
                if selection.provider.isCerebrasInference, effort == "minimal" { throw Failure.unsupportedParameter }
                body["reasoning_effort"] = effort == "xhigh" ? "high" : effort
            }
            if selection.provider.isCerebrasInference, selection.model.id == "qwen-3.8-27b" { body["clear_thinking"] = false }
            if let text = raw["text"] as? [String: Any], let format = text["format"] as? [String: Any] {
                guard tools.isEmpty || format["type"] as? String == "text" else { throw Failure.unsupportedParameter }
                switch format["type"] as? String {
                case "text": break
                case "json_object": body["response_format"] = ["type": "json_object"]
                case "json_schema":
                    guard let name = format["name"] as? String, let schema = format["schema"] as? [String: Any] else { throw Failure.unsupportedParameter }
                    try checkSchema(schema)
                    body["response_format"] = ["type": "json_schema", "json_schema": ["name": name, "schema": schema, "strict": try boolean(format["strict"], default: false)]]
                default: throw Failure.unsupportedParameter
                }
            }
            if !absent(raw["max_output_tokens"]) { body["max_completion_tokens"] = try integer(raw["max_output_tokens"], default: 1, range: 1...10_000_000) }
            for field in ["temperature", "top_p"] where !absent(raw[field]) {
                guard let number = raw[field] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      (0...(field == "temperature" ? 2.0 : 1.0)).contains(number.doubleValue) else { throw Failure.invalidRequest }
                body[field] = number
            }
        }
        return Request(localModelID: localID, provider: selection.provider, model: selection.model, threadID: threadID,
                       stream: stream, body: try json(body), tools: tools, toolNaming: toolNaming, allowedTools: allowed, requiredTool: required,
                       maximumCalls: maximumCalls, historyCallIDs: history.callIDs, capsules: capsules, responseConfiguration: configuration)
    }

    private static func responseConfiguration(_ raw: [String: Any], parallel: Bool) throws -> [String: Any] {
        guard !(try boolean(raw["background"], default: false)) else { throw Failure.unsupportedParameter }
        if !absent(raw["instructions"]), !(raw["instructions"] is String) { throw Failure.invalidRequest }
        var text: [String: Any] = ["format": ["type": "text"]]
        if !absent(raw["text"]) {
            guard let supplied = raw["text"] as? [String: Any], Set(supplied.keys).isSubset(of: ["format", "verbosity"]) else { throw Failure.unsupportedParameter }
            if let format = supplied["format"] {
                guard let value = format as? [String: Any], let type = value["type"] as? String else { throw Failure.invalidRequest }
                switch type {
                case "text", "json_object": guard Set(value.keys) == ["type"] else { throw Failure.unsupportedParameter }
                case "json_schema":
                    guard Set(value.keys).isSubset(of: ["type", "name", "schema", "strict", "description"]), let name = value["name"] as? String,
                          validName(name), let schema = value["schema"] as? [String: Any] else { throw Failure.invalidRequest }
                    try checkSchema(schema); _ = try boolean(value["strict"], default: false)
                    if !absent(value["description"]), !(value["description"] is String) { throw Failure.invalidRequest }
                default: throw Failure.unsupportedParameter
                }
                var normalized = value
                if type == "json_schema" { normalized["strict"] = value["strict"] ?? NSNull(); normalized["description"] = value["description"] ?? NSNull() }
                text["format"] = normalized
            }
            if let verbosity = supplied["verbosity"] { guard let value = verbosity as? String, ["low", "medium", "high"].contains(value) else { throw Failure.invalidRequest }; text["verbosity"] = value }
        }
        var reasoning: Any = NSNull()
        if !absent(raw["reasoning"]) {
            guard let supplied = raw["reasoning"] as? [String: Any], Set(supplied.keys).isSubset(of: ["effort", "summary"]) else { throw Failure.unsupportedParameter }
            if !absent(supplied["effort"]) { guard let effort = supplied["effort"] as? String, ["none", "low", "medium", "high", "xhigh"].contains(effort) else { throw Failure.unsupportedParameter } }
            if !absent(supplied["summary"]) { guard let summary = supplied["summary"] as? String, ["auto", "concise", "detailed"].contains(summary) else { throw Failure.unsupportedParameter } }
            reasoning = ["effort": supplied["effort"] ?? NSNull(), "summary": supplied["summary"] ?? NSNull()]
        }
        var metadata: [String: String] = [:]
        if !absent(raw["metadata"]) {
            guard let supplied = raw["metadata"] as? [String: String], supplied.count <= 16,
                  supplied.allSatisfy({ $0.key.count <= 64 && $0.value.count <= 512 }) else { throw Failure.invalidRequest }; metadata = supplied
        }
        for field in ["safety_identifier", "prompt_cache_key"] where !absent(raw[field]) {
            guard let value = raw[field] as? String, value.utf8.count <= 512 else { throw Failure.invalidRequest }
        }
        if !absent(raw["include"]) { guard let include = raw["include"] as? [String], include.allSatisfy({ $0 == "reasoning.encrypted_content" }) else { throw Failure.unsupportedParameter } }
        if !absent(raw["stream_options"]) {
            guard let options = raw["stream_options"] as? [String: Any], Set(options.keys).isSubset(of: ["include_obfuscation"]), !(try boolean(options["include_obfuscation"], default: false)) else { throw Failure.unsupportedParameter }
        }
        for field in ["max_output_tokens", "max_tool_calls"] where !absent(raw[field]) { _ = try integer(raw[field], default: 1, range: 1...(field == "max_tool_calls" ? 128 : 10_000_000)) }
        for field in ["temperature", "top_p"] where !absent(raw[field]) {
            guard let value = raw[field] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  (0...(field == "temperature" ? 2.0 : 1.0)).contains(value.doubleValue) else { throw Failure.invalidRequest }
        }
        func normalizedTool(_ value: [String: Any]) -> [String: Any] {
            var result = value
            if value["type"] as? String == "function" { result["description"] = value["description"] ?? NSNull(); result["strict"] = value["strict"] ?? NSNull() }
            if value["type"] as? String == "namespace", let children = value["tools"] as? [[String: Any]] { result["tools"] = children.map(normalizedTool) }
            return result
        }
        return ["previous_response_id": NSNull(), "instructions": raw["instructions"] ?? NSNull(),
                "tools": (raw["tools"] as? [[String: Any]] ?? []).map(normalizedTool), "tool_choice": absent(raw["tool_choice"]) ? "auto" : raw["tool_choice"]!,
                "truncation": "disabled", "parallel_tool_calls": parallel, "text": text, "temperature": absent(raw["temperature"]) ? 1 : raw["temperature"]!, "top_p": absent(raw["top_p"]) ? 1 : raw["top_p"]!,
                "presence_penalty": 0, "frequency_penalty": 0, "top_logprobs": 0, "reasoning": reasoning,
                "max_output_tokens": raw["max_output_tokens"] ?? NSNull(), "max_tool_calls": raw["max_tool_calls"] ?? NSNull(), "store": false, "background": false,
                "service_tier": "default", "metadata": metadata, "safety_identifier": NSNull(), "prompt_cache_key": NSNull()]
    }

    private static func chatCompletionToolDescription(_ tool: Tool) throws -> String {
        // Describe the final alias only after active tools have been rebound to
        // their original history indices. Native Responses keeps its own names.
        let qualified = tool.namespace.map { $0 + "." + tool.name } ?? tool.name
        let identity = "Native tool: \(qualified).\nNative namespace: \(tool.namespace ?? "(none)"); native name: \(tool.name).\nCallable API function: \(tool.wireName).\nWhen instructions refer to this native tool, call this API function with its declared arguments.\n\n"
        // Existing tool descriptions (including custom grammars) remain intact
        // at their existing limit; the separately bounded identity is additive.
        guard identity.utf8.count <= 1_024, tool.description.utf8.count <= 64_000 else { throw Failure.invalidTool }
        return identity + tool.description
    }

    private static func semanticToolName(name: String, namespace: String?) -> String {
        // Native names are validated ASCII. Dots are legal natively but not in
        // Chat Completions; the digest retains their exact qualified identity.
        let stem = String(name.replacingOccurrences(of: ".", with: "_").prefix(38))
        let identity = (namespace ?? "") + "\u{0}" + name
        let suffix = SHA256.hash(data: Data(identity.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        return stem + "__" + suffix
    }

    private static func parseTools(_ value: Any?, naming: ToolNaming) throws -> [Tool] {
        if absent(value) { return [] }
        guard let definitions = value as? [[String: Any]], definitions.count <= 256 else { throw Failure.invalidTool }
        var result: [Tool] = [], identities = Set<String>(), wireNames = Set<String>()
        func add(_ definition: [String: Any], namespace: String?) throws {
            guard let type = definition["type"] as? String, ["function", "custom"].contains(type),
                  let name = definition["name"] as? String, validName(name), result.count < 256 else { throw Failure.invalidTool }
            if !absent(definition["description"]), !(definition["description"] is String) { throw Failure.invalidTool }
            if !absent(definition["strict"]), strictBool(definition["strict"]) == nil { throw Failure.invalidTool }
            let custom = type == "custom"
            let schema: [String: Any]
            if custom {
                // Put the literal-input contract on the argument the provider fills,
                // while preserving the complete native grammar in the description.
                let inputDescription = "Literal native tool input. Follow the exact text or grammar contract in this function's description, including delimiters and newlines. Encode the contents once as this JSON string; do not add quoting, JSON, shell syntax or Markdown fences unless the native contract requires them."
                schema = ["type": "object", "properties": ["input": ["type": "string", "description": inputDescription]], "required": ["input"], "additionalProperties": false]
            } else {
                guard var parameters = definition["parameters"] as? [String: Any], parameters["type"] as? String == "object" else { throw Failure.invalidTool }
                try checkSchema(parameters)
                // Close named top-level arguments unless the native definition explicitly
                // declares an open map. Nested JSON Schema unions/references retain their
                // standard additionalProperties semantics.
                if parameters["additionalProperties"] == nil, parameters["properties"] != nil { parameters["additionalProperties"] = false }
                schema = parameters
            }
            let description = custom ? try customToolDescription(definition) : (definition["description"] as? String ?? "")
            let wireName = naming == .legacy ? "computa_tool_\(result.count)" : semanticToolName(name: name, namespace: namespace)
            let tool = Tool(name: name, namespace: namespace, wireName: wireName, custom: custom,
                            schema: schema, description: description)
            // Validate the complete catalog before filtering, so a collision
            // cannot be hidden or resolved by changing declaration order.
            guard identities.insert(tool.identity).inserted, wireNames.insert(wireName).inserted,
                  wireName.utf8.count <= 64, wireName.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
                  tool.description.utf8.count <= 64_000 else { throw Failure.invalidTool }
            result.append(tool)
        }
        for definition in definitions {
            if definition["type"] as? String == "namespace" {
                guard let namespace = definition["name"] as? String, validName(namespace),
                      let children = definition["tools"] as? [[String: Any]] else { throw Failure.invalidTool }
                for child in children { try add(child, namespace: namespace) }
            } else { try add(definition, namespace: nil) }
        }
        return result
    }

    private static func customToolDescription(_ definition: [String: Any]) throws -> String {
        let original = definition["description"] as? String ?? ""
        guard original.utf8.count <= 64_000 else { throw Failure.invalidTool }
        let format: [String: Any]
        if let supplied = definition["format"] {
            guard let value = supplied as? [String: Any] else { throw Failure.invalidTool }; format = value
        } else { format = ["type": "text"] }
        let contract: String
        switch format["type"] as? String {
        case "text":
            guard Set(format.keys) == ["type"] else { throw Failure.invalidTool }
            contract = "The native tool accepts raw text."
        case "grammar":
            guard Set(format.keys) == ["type", "syntax", "definition"], let syntax = format["syntax"] as? String,
                  ["lark", "regex"].contains(syntax), let grammar = format["definition"] as? String,
                  !grammar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  grammar.utf8.count <= 16_384 else { throw Failure.invalidTool }
            // Preserve the native contract verbatim. The gateway does not claim
            // to implement provider-side constrained decoding or a Lark parser.
            contract = "The decoded input string must satisfy this native \(syntax) grammar. Grammar definition (verbatim):\n\(grammar)"
        default: throw Failure.invalidTool
        }
        let description = original + "\n\nCustom tool transport: call this function with exactly one string argument named input. The JSON object is only the transport wrapper; the decoded input string is passed unchanged to the native custom tool. Any instruction above to use freeform input or not wrap it in JSON applies to that string's contents, not the transport object. Do not add another layer of JSON encoding inside input.\n" + contract
        guard description.utf8.count <= 64_000 else { throw Failure.invalidTool }
        return description
    }

    private struct History { let messages: [[String: Any]]; let callIDs: Set<String> }
    private static func messages(_ raw: [String: Any], tools: [Tool], selection: APIProviderCatalog.Selection,
                                 threadID: String, capsules: APIReasoningCapsules, toolNaming: ToolNaming) throws -> History {
        var messages: [[String: Any]] = [], seen = Set<String>(), pending = Set<String>(), pendingCustom = Set<String>()
        // Native compaction deliberately offers no tools while retaining completed
        // calls/results. Their display-only aliases cannot recover declaration
        // indices, and must never become callable tools in the new request.
        var uncataloguedKinds = [String: Bool]()
        var reasoning: APIReasoningCapsules.Payload?, assistant: [String: Any]?, calls: [[String: Any]] = []
        func flush() throws {
            guard var message = assistant else {
                guard reasoning == nil else { throw Failure.invalidHistory }; return
            }
            if !calls.isEmpty { message["tool_calls"] = calls }
            if let value = reasoning {
                guard Set(value.callIDs) == Set(calls.compactMap { $0["id"] as? String }) else { throw Failure.invalidReasoning }
                guard let text = value.reasoning, value.remoteEncryptedContent == nil else { throw Failure.invalidReasoning }
                guard (value.toolNaming ?? ToolNaming.legacy.rawValue) == toolNaming.rawValue else { throw Failure.invalidReasoning }
                message["reasoning"] = text
            }
            messages.append(message); assistant = nil; calls = []; reasoning = nil
        }
        if let instructions = raw["instructions"] as? String, !instructions.isEmpty { messages.append(["role": "system", "content": instructions]) }
        let items: [[String: Any]]
        if let input = raw["input"] as? String { items = [["role": "user", "content": input]] }
        else if let input = raw["input"] as? [[String: Any]] { items = input }
        else { throw Failure.invalidRequest }
        guard items.count <= 8_192 else { throw Failure.invalidRequest }
        var reasoningIDs = Set<String>()
        for item in items {
            let type = item["type"] as? String ?? "message"
            switch type {
            case "reasoning":
                try flush()
                if selection.provider.wireAPI == .chatCompletions {
                    guard let id = item["id"] as? String, let capsule = item["encrypted_content"] as? String,
                          reasoningIDs.insert(id).inserted else { throw Failure.invalidReasoning }
                    reasoning = try capsules.open(capsule, itemID: id, providerID: selection.provider.id, modelID: selection.model.id, baseURL: selection.provider.baseURL, threadID: threadID)
                }
            case "message":
                guard let originalRole = item["role"] as? String, ["system", "developer", "user", "assistant"].contains(originalRole) else { throw Failure.invalidHistory }
                let role = selection.provider.isCerebrasInference && selection.model.id == "qwen-3.8-27b" && originalRole == "developer" ? "system" : originalRole
                if selection.provider.isCerebrasInference, role != "user", containsImage(item["content"]) { throw Failure.unsupportedModality }
                if role == "assistant", assistant == nil {
                    assistant = ["role": role, "content": try content(item["content"], images: selection.model.supportsImages, cerebras: selection.provider.isCerebrasInference)]
                } else {
                    try flush(); guard pending.isEmpty else { throw Failure.invalidHistory }
                    if role == "assistant" { assistant = ["role": role, "content": try content(item["content"], images: selection.model.supportsImages, cerebras: selection.provider.isCerebrasInference)] }
                    else { messages.append(["role": role, "content": try content(item["content"], images: selection.model.supportsImages, cerebras: selection.provider.isCerebrasInference)]) }
                }
            case "function_call", "custom_tool_call":
                guard let id = item["call_id"] as? String, validCallID(id), seen.insert(id).inserted,
                      let name = item["name"] as? String else { throw Failure.invalidHistory }
                let custom = type == "custom_tool_call"
                let tool = tools.first(where: { $0.name == name && $0.namespace == item["namespace"] as? String })
                let wireName: String
                if let tool {
                    guard tool.custom == custom else { throw Failure.invalidHistory }
                    wireName = tool.wireName
                } else {
                    // A nonempty catalog remains authoritative for historical
                    // names, kinds and argument schemas.
                    guard tools.isEmpty, validName(name), absent(item["namespace"]) || item["namespace"] is String else {
                        throw Failure.invalidHistory
                    }
                    let namespace = item["namespace"] as? String
                    guard namespace.map(validName) ?? true else { throw Failure.invalidHistory }
                    let identity = (namespace ?? "") + "\u{0}" + name
                    if let previous = uncataloguedKinds[identity] {
                        guard previous == custom else { throw Failure.invalidHistory }
                    } else {
                        guard uncataloguedKinds.count < 256 else { throw Failure.invalidHistory }
                        uncataloguedKinds[identity] = custom
                    }
                    wireName = semanticToolName(name: name, namespace: namespace)
                }
                let arguments: String
                if custom {
                    guard let input = item["input"] as? String else { throw Failure.invalidHistory }
                    arguments = String(decoding: try json(["input": input]), as: UTF8.self); pendingCustom.insert(id)
                } else {
                    guard let value = item["arguments"] as? String else { throw Failure.invalidHistory }
                    arguments = value
                }
                if let tool { try validateHistoricalArguments(arguments, tool: tool) }
                else {
                    // No unavailable schema is invented for already-completed
                    // history; retain the same bounded JSON-object requirement.
                    guard arguments.utf8.count <= maximumText, let bytes = arguments.data(using: .utf8),
                          (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any] else {
                        throw Failure.invalidArguments
                    }
                }
                if assistant == nil { assistant = ["role": "assistant", "content": NSNull()] }
                calls.append(["id": id, "type": "function", "function": ["name": wireName, "arguments": arguments]])
                pending.insert(id)
            case "function_call_output", "custom_tool_call_output":
                try flush()
                guard let id = item["call_id"] as? String, pending.remove(id) != nil,
                      pendingCustom.contains(id) == (type == "custom_tool_call_output") else { throw Failure.invalidHistory }
                if containsImage(item["output"]), selection.provider.isCerebrasInference || !selection.model.supportsToolImages { throw Failure.unsupportedModality }
                messages.append(["role": "tool", "tool_call_id": id, "content": try content(item["output"], images: selection.model.supportsImages, cerebras: selection.provider.isCerebrasInference)])
            default: throw Failure.unsupportedParameter
            }
        }
        try flush()
        guard pending.isEmpty, !messages.isEmpty else { throw Failure.invalidHistory }
        return History(messages: try chatTemplateMessages(messages, selection: selection), callIDs: seen)
    }

    private static func chatTemplateMessages(_ messages: [[String: Any]], selection: APIProviderCatalog.Selection) throws -> [[String: Any]] {
        guard selection.provider.wireAPI == .chatCompletions, selection.provider.isCerebrasInference,
              selection.model.id == "qwen-3.8-27b" else { return messages }
        // This provider's Qwen template rejects system messages after conversation
        // content. Developer instructions were already mapped to system above.
        // Gather only those trusted roles, in their original order; tool results
        // and user/assistant content retain their roles, order and call identities.
        var instructions: [String] = [], conversation: [[String: Any]] = [], bytes = 0
        for message in messages {
            if message["role"] as? String == "system" {
                guard let content = message["content"] as? String else { throw Failure.invalidHistory }
                bytes += content.utf8.count + (instructions.isEmpty ? 0 : 2)
                guard bytes <= maximumText else { throw Failure.invalidRequest }
                instructions.append(content)
            } else { conversation.append(message) }
        }
        guard !instructions.isEmpty else { return conversation }
        return [["role": "system", "content": instructions.joined(separator: "\n\n")]] + conversation
    }

    private static func containsImage(_ value: Any?) -> Bool {
        (value as? [[String: Any]])?.contains { $0["type"] as? String == "input_image" } == true
    }
    private static func responseHistory(_ value: Any?, selection: APIProviderCatalog.Selection,
                                        threadID: String, capsules: APIReasoningCapsules) throws -> Any {
        if let text = value as? String { return text }
        guard var items = value as? [[String: Any]] else { throw Failure.invalidHistory }
        var seen = Set<String>()
        for index in items.indices where items[index]["type"] as? String == "reasoning" {
            guard let id = items[index]["id"] as? String, seen.insert(id).inserted,
                  let summaries = items[index]["summary"] as? [[String: Any]],
                  summaries.allSatisfy({ $0["type"] as? String == "summary_text" && $0["text"] is String }) else { throw Failure.invalidReasoning }
            if let encrypted = items[index]["encrypted_content"] as? String {
                let payload = try capsules.open(encrypted, itemID: id, providerID: selection.provider.id, modelID: selection.model.id,
                                                baseURL: selection.provider.baseURL, threadID: threadID)
                guard payload.reasoning == nil, let opaque = payload.remoteEncryptedContent, payload.remoteItemID == id else { throw Failure.invalidReasoning }
                items[index]["encrypted_content"] = opaque
            } else if !absent(items[index]["encrypted_content"]) { throw Failure.invalidReasoning }
        }
        return items
    }
    private static func content(_ value: Any?, images: Bool, cerebras: Bool) throws -> Any {
        if let string = value as? String { guard string.utf8.count <= maximumText else { throw Failure.invalidRequest }; return string }
        guard let parts = value as? [[String: Any]], parts.count <= 2_048 else { throw Failure.invalidHistory }
        var converted: [[String: Any]] = [], text = "", imagePresent = false
        for part in parts {
            switch part["type"] as? String {
            case "input_text", "output_text", "text":
                guard let value = part["text"] as? String else { throw Failure.invalidHistory }
                text += value; converted.append(["type": "text", "text": value])
            case "input_image":
                guard images, let url = part["image_url"] as? String,
                      url.hasPrefix("data:image/") || URL(string: url)?.scheme == "https" else { throw Failure.unsupportedModality }
                if cerebras {
                    let prefixes = ["data:image/png;base64,", "data:image/jpeg;base64,"]
                    guard let prefix = prefixes.first(where: { url.hasPrefix($0) }), url.utf8.count <= maximumText,
                          let imageData = Data(base64Encoded: String(url.dropFirst(prefix.count))), !imageData.isEmpty else { throw Failure.unsupportedModality }
                }
                var image: [String: Any] = ["url": url]
                if !cerebras, let detail = part["detail"] as? String {
                    guard ["auto", "low", "high", "original"].contains(detail) else { throw Failure.unsupportedModality }
                    image["detail"] = detail == "original" ? "high" : detail
                }
                imagePresent = true; converted.append(["type": "image_url", "image_url": image])
            default: throw Failure.unsupportedModality
            }
        }
        return imagePresent ? converted : text
    }

    static func decode(_ result: APIProviderHTTPClient.Result, request: Request) throws -> Reply {
        switch try decodeForCorrection(result, request: request) {
        case .reply(let reply): return reply
        case .argumentsRejected: throw Failure.invalidArguments
        }
    }

    static func decodeForCorrection(_ result: APIProviderHTTPClient.Result, request: Request,
                                    onArgumentRejection: ((ArgumentValidationDiagnostic) -> Void)? = nil,
                                    onInvalidResponse: ((InvalidResponseDiagnostic) -> Void)? = nil) throws -> DecodeOutcome {
        let format: InvalidResponseDiagnostic.Format = request.provider.wireAPI == .responses ? .responsesJSON
            : (result.contentType.contains("text/event-stream") ? .chatSSE : .chatJSON)
        let observeResponseGuard: InvalidResponseObserver? = onInvalidResponse.map { callback in
            { guardID in callback(.init(format: format, guardID: guardID)) }
        }
        if request.provider.wireAPI == .responses { return .reply(try decodeResponses(result.body, request: request, observe: observeResponseGuard)) }
        let envelope: [String: Any], textDeltas: [String], argumentDeltas: [[String]]
        let rawCorrectionEligible: Bool, envelopeShapeValid: Bool, unambiguousJSON: Bool, streamShapeAndUsageValid: Bool
        let envelopeRejection: ArgumentValidationDiagnostic.EnvelopeRejection?
        let jsonRejection: APIModelCorrectionJSON.RejectionDiagnostic?
        if result.contentType.contains("text/event-stream") {
            let assembled = try assembleChatStream(result.body, cerebras: request.provider.isCerebrasInference, diagnostics: onArgumentRejection != nil, observe: observeResponseGuard)
            envelope = assembled.object; textDeltas = assembled.text; argumentDeltas = assembled.arguments
            rawCorrectionEligible = assembled.correctionEligible
            envelopeShapeValid = assembled.envelopeShapeValid; unambiguousJSON = assembled.unambiguousJSON
            envelopeRejection = assembled.envelopeRejection; jsonRejection = assembled.jsonRejection
            streamShapeAndUsageValid = assembled.streamShapeAndUsageValid
        } else {
            guard let object = try responseJSONValue(result.body, observe: observeResponseGuard) as? [String: Any] else { throw invalidResponse(.chatRootObject, observeResponseGuard) }
            envelope = object; textDeltas = []; argumentDeltas = []
            envelopeShapeValid = correctionEnvelopeShape(object, streaming: false)
            envelopeRejection = envelopeShapeValid ? nil : correctionEnvelopeRejection(object, streaming: false)
            unambiguousJSON = APIModelCorrectionJSON.isUnambiguous(result.body)
            jsonRejection = unambiguousJSON || onArgumentRejection == nil ? nil : APIModelCorrectionJSON.rejectionDiagnostic(result.body)
            streamShapeAndUsageValid = true
            rawCorrectionEligible = envelopeShapeValid && unambiguousJSON
        }
        guard envelope["model"] as? String == request.model.id else { throw Failure.modelMismatch }
        guard let choices = envelope["choices"] as? [[String: Any]], choices.count == 1,
              try responseInteger(choices[0]["index"], default: 0, range: 0...0, guardID: .chatChoiceIndex, observe: observeResponseGuard) == 0,
              let message = choices[0]["message"] as? [String: Any], message["role"] as? String == "assistant",
              let finish = choices[0]["finish_reason"] as? String else { throw invalidResponse(.chatChoiceEnvelope, observeResponseGuard) }
        guard ["stop", "tool_calls"].contains(finish) else { throw Failure.incompleteResponse }
        let text: String
        if absent(message["content"]) { text = "" }
        else if let value = message["content"] as? String { text = value }
        else { throw invalidResponse(.chatContentType, observeResponseGuard) }
        guard absent(message["refusal"]), absent(message["function_call"]) else { throw invalidResponse(.chatUnsupportedMessageFields, observeResponseGuard) }
        let calls: [[String: Any]]
        if absent(message["tool_calls"]) { calls = [] }
        else if let value = message["tool_calls"] as? [[String: Any]] { calls = value }
        else { throw invalidResponse(.chatCallsType, observeResponseGuard) }
        guard calls.count <= request.maximumCalls, !request.requiredTool || !calls.isEmpty,
              (finish == "tool_calls") == !calls.isEmpty else { throw invalidResponse(.chatCallFinishConsistency, observeResponseGuard) }
        // Complete the entire envelope, identities, reasoning and usage BEFORE
        // an argument-only classification. A first bad call cannot hide a later
        // unknown tool, duplicate ID, malformed reasoning or invalid usage.
        let normalizedUsage = try usage(envelope["usage"], responses: false, observe: observeResponseGuard)
        guard absent(message["reasoning"]) || message["reasoning"] is String else { throw invalidResponse(.chatReasoningType, observeResponseGuard) }
        var callIDs = request.historyCallIDs
        var validatedCalls: [(id: String, tool: Tool, arguments: String)] = []
        for call in calls {
            guard call["type"] as? String == "function", let id = call["id"] as? String, validCallID(id), callIDs.insert(id).inserted,
                  let function = call["function"] as? [String: Any], let wireName = function["name"] as? String,
                  request.allowedTools.contains(wireName), let tool = request.tools.first(where: { $0.wireName == wireName }),
                  let arguments = function["arguments"] as? String else { throw Failure.invalidTool }
            validatedCalls.append((id, tool, arguments))
        }
        var parsedArguments: [[String: Any]] = [], argumentsRejected = false
        var rejectionReason: ArgumentValidationDiagnostic.Reason?, rejectedCount = 0
        var rejectionDetails: [ArgumentRejectionDetail] = []
        func observe(_ reason: ArgumentValidationDiagnostic.Reason) {
            rejectedCount += 1
            if let prior = rejectionReason, prior != reason { rejectionReason = .multipleKinds }
            else { rejectionReason = reason }
        }
        func emitArgumentRejection(oversized: Bool = false) {
            guard let reason = rejectionReason else { return }
            onArgumentRejection?(.init(reason: reason, envelopeRejection: envelopeRejection, jsonRejection: jsonRejection, schemaFailures: rejectionDetails.isEmpty ? nil : rejectionDetails.prefix(2).map { .init(toolIndex: $0.toolIndex, constraint: $0.constraint) }, callCount: validatedCalls.count, rejectedCount: rejectedCount,
                envelopeShapeValid: envelopeShapeValid, unambiguousJSON: unambiguousJSON,
                streamShapeAndUsageValid: streamShapeAndUsageValid, knownUsage: correctionUsage(normalizedUsage) != nil,
                correctionEligible: rawCorrectionEligible && correctionUsage(normalizedUsage) != nil && !oversized))
        }
        for call in validatedCalls {
            guard call.arguments.utf8.count <= maximumText else {
                observe(.oversized); emitArgumentRejection(oversized: true); throw Failure.invalidArguments
            }
            do { parsedArguments.append(try validatedArguments(call.arguments, tool: call.tool, onRejection: observe, onSchemaMismatch: { violation in
                if rejectionDetails.count < 8, let index = request.tools.firstIndex(where: { $0.wireName == call.tool.wireName }) {
                    rejectionDetails.append(.init(toolIndex: index, wireName: call.tool.wireName, constraint: violation.constraint, path: violation.path))
                }
            })) }
            catch let failure as Failure where failure == .invalidArguments {
                argumentsRejected = true; parsedArguments.append([:])
            }
        }
        if let reasoning = message["reasoning"] as? String, !reasoning.isEmpty {
            // Same encoded-size guard as seal, without generating or publishing
            // a capsule for the rejected response. Generated response IDs have
            // this fixed ASCII width; exact call IDs and reasoning are retained.
            try APIReasoningCapsules.validatePayload(.init(reasoning: reasoning, callIDs: validatedCalls.map(\.id),
                responseID: "resp_" + String(repeating: "0", count: 32), toolNaming: request.toolNaming.rawValue))
        }
        if argumentsRejected {
            emitArgumentRejection()
            guard rawCorrectionEligible, let known = correctionUsage(normalizedUsage) else { throw Failure.invalidArguments }
            return .argumentsRejected(known, rejectionDetails)
        }
        let responseID = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var output: [[String: Any]] = [], actualIDs: [String] = []
        for (index, call) in validatedCalls.enumerated() {
            let tool = call.tool
            var item: [String: Any] = ["id": (tool.custom ? "ctc_" : "fc_") + UUID().uuidString, "type": tool.custom ? "custom_tool_call" : "function_call", "status": "completed", "call_id": call.id, "name": tool.name]
            if let namespace = tool.namespace { item["namespace"] = namespace }
            if tool.custom { item["input"] = parsedArguments[index]["input"] as! String } else { item["arguments"] = call.arguments }
            output.append(item); actualIDs.append(call.id)
        }
        if !text.isEmpty {
            output.insert(["id": "msg_" + UUID().uuidString, "type": "message", "status": "completed", "role": "assistant",
                           "phase": calls.isEmpty ? "final_answer" : "commentary", "content": [["type": "output_text", "text": text, "annotations": []]]], at: 0)
        }
        if let reasoning = message["reasoning"] as? String, !reasoning.isEmpty {
            let id = "rs_" + responseID
            let capsule = try request.capsules.seal(.init(reasoning: reasoning, callIDs: actualIDs, responseID: responseID, toolNaming: request.toolNaming.rawValue), itemID: id,
                                                   providerID: request.provider.id, modelID: request.model.id, baseURL: request.provider.baseURL, threadID: request.threadID)
            output.insert(["id": id, "type": "reasoning", "status": "completed", "summary": [], "encrypted_content": capsule], at: 0)
        } else if !absent(message["reasoning"]) && !(message["reasoning"] is String) { throw invalidResponse(.chatRetainedReasoningType, observeResponseGuard) }
        guard !output.isEmpty else { throw invalidResponse(.chatEmptyOutput, observeResponseGuard) }
        let resource = response(id: responseID, request: request, output: output, text: text, usage: normalizedUsage)
        return .reply(Reply(response: resource,
                           textDeltas: textDeltas.isEmpty && !text.isEmpty ? [text] : textDeltas, argumentDeltas: argumentDeltas,
                           finalTextSource: calls.isEmpty ? finalTextSource(text, response: resource) : nil))
    }

    private static func decodeResponses(_ data: Data, request: Request, observe: InvalidResponseObserver?) throws -> Reply {
        guard let raw = try responseJSONValue(data, observe: observe) as? [String: Any], raw["object"] as? String == "response",
              raw["status"] as? String == "completed", absent(raw["error"]), absent(raw["incomplete_details"]),
              let original = raw["output"] as? [[String: Any]], !original.isEmpty else { throw Failure.incompleteResponse }
        guard raw["model"] as? String == request.model.id else { throw Failure.modelMismatch }
        var output: [[String: Any]] = [], text = "", ids = request.historyCallIDs, itemIDs = Set<String>(), count = 0
        let responseID = raw["id"] as? String ?? "resp_" + UUID().uuidString
        for value in original {
            guard let type = value["type"] as? String, let id = value["id"] as? String, !id.isEmpty, itemIDs.insert(id).inserted else { throw invalidResponse(.responsesItemIdentity, observe) }
            switch type {
            case "function_call", "custom_tool_call":
                guard absent(value["status"]) || value["status"] as? String == "completed" else { throw Failure.incompleteResponse }
                guard let name = value["name"] as? String,
                      let tool = request.tools.first(where: { $0.name == name && $0.namespace == value["namespace"] as? String }),
                      tool.custom == (type == "custom_tool_call"), request.allowedTools.contains(tool.wireName),
                      let callID = value["call_id"] as? String, validCallID(callID), ids.insert(callID).inserted else { throw Failure.invalidTool }
                if tool.custom {
                    guard let input = value["input"] as? String else { throw Failure.invalidArguments }
                    _ = try validatedArguments(String(decoding: try json(["input": input]), as: UTF8.self), tool: tool)
                } else {
                    guard let arguments = value["arguments"] as? String else { throw Failure.invalidArguments }
                    _ = try validatedArguments(arguments, tool: tool)
                }
                var item: [String: Any] = ["id": id, "type": type, "status": "completed", "name": tool.name, "call_id": callID]
                item[tool.custom ? "input" : "arguments"] = value[tool.custom ? "input" : "arguments"]
                if let namespace = tool.namespace { item["namespace"] = namespace }; output.append(item); count += 1
            case "message":
                guard value["role"] as? String == "assistant", value["status"] as? String == "completed",
                      let parts = value["content"] as? [[String: Any]], parts.allSatisfy({ $0["type"] as? String == "output_text" && $0["text"] is String }) else { throw invalidResponse(.responsesMessage, observe) }
                let messageText = parts.compactMap { $0["text"] as? String }.joined(); text += messageText
                output.append(["id": id, "type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": messageText, "annotations": []]]])
            case "reasoning":
                guard let summary = value["summary"] as? [[String: Any]], summary.allSatisfy({ $0["type"] as? String == "summary_text" && $0["text"] is String }) else { throw invalidResponse(.responsesSummary, observe) }
                var item: [String: Any] = ["id": id, "type": type, "status": "completed", "summary": summary]
                if let encrypted = value["encrypted_content"] as? String {
                    let payload = APIReasoningCapsules.Payload(reasoning: nil, callIDs: [], responseID: responseID, remoteEncryptedContent: encrypted, remoteItemID: id)
                    item["encrypted_content"] = try request.capsules.seal(payload, itemID: id, providerID: request.provider.id,
                                                                         modelID: request.model.id, baseURL: request.provider.baseURL, threadID: request.threadID)
                } else if !absent(value["encrypted_content"]) { throw invalidResponse(.responsesEncryptedType, observe) }
                output.append(item)
            default: throw invalidResponse(.responsesItemType, observe)
            }
        }
        guard count <= request.maximumCalls, !request.requiredTool || count > 0 else { throw Failure.invalidTool }
        let resource = response(id: "resp_" + UUID().uuidString, request: request, output: output, text: text,
                                usage: try usage(raw["usage"], responses: true, observe: observe))
        return Reply(response: resource, textDeltas: text.isEmpty ? [] : [text], argumentDeltas: [],
                     finalTextSource: count == 0 ? finalTextSource(text, response: resource) : nil)
    }

    private struct ChatStream {
        let object: [String: Any]; let text: [String]; let arguments: [[String]]; let correctionEligible: Bool
        let envelopeShapeValid: Bool; let unambiguousJSON: Bool; let streamShapeAndUsageValid: Bool
        let envelopeRejection: ArgumentValidationDiagnostic.EnvelopeRejection?
        let jsonRejection: APIModelCorrectionJSON.RejectionDiagnostic?
    }
    private static func correctionEnvelopeShape(_ value: [String: Any], streaming: Bool) -> Bool {
        guard absent(value["error"]), let id = value["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              absent(value["object"]) || value["object"] as? String == (streaming ? "chat.completion.chunk" : "chat.completion"),
              absent(value["system_fingerprint"]) || value["system_fingerprint"] is String else { return false }
        if !absent(value["created"]), (try? integer(value["created"], default: -1, range: 0...4_102_444_800)) == nil { return false }
        return true
    }
    /// Explain only an already-failed shape gate. Keep its authority and exact
    /// integer validation above unchanged; never retain the offending value.
    private static func correctionEnvelopeRejection(_ value: [String: Any], streaming: Bool) -> ArgumentValidationDiagnostic.EnvelopeRejection {
        if !absent(value["error"]) { return .errorPresent }
        if absent(value["id"]) { return .missingID }
        guard let id = value["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .invalidID }
        if !absent(value["object"]), value["object"] as? String != (streaming ? "chat.completion.chunk" : "chat.completion") { return .objectKind }
        if !absent(value["system_fingerprint"]), !(value["system_fingerprint"] is String) { return .systemFingerprintType }
        if !absent(value["created"]), (try? integer(value["created"], default: -1, range: 0...4_102_444_800)) == nil {
            guard let number = value["created"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else { return .createdNoninteger }
            return .createdOutOfRange
        }
        return .unknownShape
    }
    private static func correctionDeltaShape(_ delta: [String: Any]) -> Bool {
        if delta["role"] != nil, !(delta["role"] is String) { return false }
        for key in ["content", "reasoning"] {
            if !absent(delta[key]), !(delta[key] is String) { return false }
        }
        guard absent(delta["refusal"]), absent(delta["function_call"]) else { return false }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            for call in calls {
                if call["id"] != nil, !(call["id"] is String) { return false }
                if call["type"] != nil, call["type"] as? String != "function" { return false }
                if call["function"] != nil {
                    guard let function = call["function"] as? [String: Any] else { return false }
                    for key in ["name", "arguments"] { if function[key] != nil, !(function[key] is String) { return false } }
                }
            }
        } else if !absent(delta["tool_calls"]) { return false }
        return true
    }
    /// The documented Cerebras ErrorChunkResponse is a failure, not a partial
    /// ChatChunkResponse. Unknown fields, types, statuses and ambiguous JSON keep
    /// the existing invalid-response path. No provider text escapes classification.
    private static func cerebrasStreamFailure(_ chunk: [String: Any], data: Data) -> APIProviderHTTPClient.Failure? {
        guard data.count <= 16_384, APIModelCorrectionJSON.isUnambiguous(data),
              Set(chunk.keys) == ["error", "status_code"],
              let error = chunk["error"] as? [String: Any],
              Set(error.keys).isSubset(of: ["id", "code", "message", "param", "type"]),
              error.values.allSatisfy({ absent($0) || $0 is String }),
              let number = chunk["status_code"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue == Double(number.intValue),
              (400...599).contains(number.intValue) else { return nil }
        switch number.intValue {
        case 401, 403: return .unauthorized
        case 404: return .modelNotFound
        case 429: return APIProviderHTTPClient.rateLimitFailure(body: data)
        case 400, 413, 422: return APIProviderHTTPClient.rejectedRequest(status: number.intValue, body: data)
        default: return .unavailable
        }
    }

    private static func assembleChatStream(_ data: Data, cerebras: Bool, diagnostics: Bool = false, observe: InvalidResponseObserver?) throws -> ChatStream {
        guard let string = String(data: data, encoding: .utf8) else { throw invalidResponse(.sseUTF8, observe) }
        var done = false, model: String?, id: String?, role: String?, finish: String?, usage: Any?
        var text: [String] = [], reasoning = "", calls: [Int: (id: String, name: String, arguments: [String])] = [:]
        var correctionEligible = true, previousUsage: Data?
        var envelopeShapeValid = true, unambiguousJSON = true, streamShapeAndUsageValid = true
        var envelopeRejection: ArgumentValidationDiagnostic.EnvelopeRejection?
        var jsonRejection: APIModelCorrectionJSON.RejectionDiagnostic?
        for event in string.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            let payload = event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            if payload.isEmpty { continue }
            guard !done else { throw invalidResponse(.sseAfterDone, observe) }
            if payload == "[DONE]" { done = true; continue }
            guard let chunkData = payload.data(using: .utf8), let chunk = try responseJSONValue(chunkData, observe: observe) as? [String: Any] else {
                throw invalidResponse(.sseChunkEnvelope, observe)
            }
            // Cerebras documents errors inside an HTTP-200 SSE stream. Classify
            // only its exact bounded error envelope; never publish partial output,
            // authorize a tool, or turn a provider failure into a correction.
            let eventNames = event.components(separatedBy: "\n").filter { $0.hasPrefix("event:") }
                .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            if cerebras, eventNames.contains("error") {
                guard eventNames == ["error"], let failure = cerebrasStreamFailure(chunk, data: chunkData) else {
                    throw invalidResponse(.sseChunkEnvelope, observe)
                }
                throw failure
            }
            if cerebras, eventNames.isEmpty, let failure = cerebrasStreamFailure(chunk, data: chunkData) { throw failure }
            guard chunk["error"] == nil, let chunkModel = chunk["model"] as? String, let chunkID = chunk["id"] as? String,
                  let choices = chunk["choices"] as? [[String: Any]], choices.count <= 1 else { throw invalidResponse(.sseChunkEnvelope, observe) }
            let shapeValid = correctionEnvelopeShape(chunk, streaming: true), unambiguous = APIModelCorrectionJSON.isUnambiguous(chunkData)
            envelopeShapeValid = envelopeShapeValid && shapeValid; unambiguousJSON = unambiguousJSON && unambiguous
            if !shapeValid, envelopeRejection == nil { envelopeRejection = correctionEnvelopeRejection(chunk, streaming: true) }
            if diagnostics, !unambiguous, jsonRejection == nil { jsonRejection = APIModelCorrectionJSON.rejectionDiagnostic(chunkData) }
            correctionEligible = correctionEligible && shapeValid && unambiguous
            if !absent(chunk["usage"]) {
                if let normalized = try? Self.usage(chunk["usage"], responses: false), let bytes = try? json(normalized) {
                    if let previousUsage, previousUsage != bytes { correctionEligible = false; streamShapeAndUsageValid = false }
                    previousUsage = bytes
                } else { correctionEligible = false; streamShapeAndUsageValid = false }
            }
            if let model { guard model == chunkModel, id == chunkID else { throw invalidResponse(.sseChunkIdentity, observe) } }
            else { model = chunkModel; id = chunkID }
            if !absent(chunk["usage"]) { usage = chunk["usage"] }
            guard let choice = choices.first else { continue }
            guard try responseInteger(choice["index"], default: -1, range: 0...0, guardID: .sseChoiceIndex, observe: observe) == 0, finish == nil,
                  let delta = choice["delta"] as? [String: Any] else { throw invalidResponse(.sseChoiceDelta, observe) }
            let deltaShapeValid = correctionDeltaShape(delta)
            streamShapeAndUsageValid = streamShapeAndUsageValid && deltaShapeValid
            correctionEligible = correctionEligible && deltaShapeValid
            if !absent(choice["finish_reason"]), !(choice["finish_reason"] is String) { correctionEligible = false; streamShapeAndUsageValid = false }
            if let value = delta["role"] as? String { guard value == "assistant", role == nil || role == value else { throw invalidResponse(.sseRole, observe) }; role = value }
            if let value = delta["content"] as? String { text.append(value) } else if !absent(delta["content"]) { throw invalidResponse(.sseContentType, observe) }
            if let value = delta["reasoning"] as? String { reasoning += value } else if !absent(delta["reasoning"]) { throw invalidResponse(.sseReasoningType, observe) }
            if let rows = delta["tool_calls"] as? [[String: Any]] {
                for row in rows {
                    let index = try responseInteger(row["index"], default: -1, range: 0...127, guardID: .sseToolIndex, observe: observe)
                    var call = calls[index] ?? (id: "", name: "", arguments: [])
                    if let value = row["id"] as? String { guard call.id.isEmpty else { throw invalidResponse(.sseRepeatedCallID, observe) }; call.id = value }
                    if let type = row["type"] as? String { guard type == "function" else { throw Failure.invalidTool } }
                    if let function = row["function"] as? [String: Any] {
                        if let value = function["name"] as? String { call.name += value }
                        if let value = function["arguments"] as? String { call.arguments.append(value) }
                    }
                    calls[index] = call
                }
            } else if !absent(delta["tool_calls"]) { throw invalidResponse(.sseCallsType, observe) }
            if let value = choice["finish_reason"] as? String { finish = value }
        }
        guard done, let model, let id, let finish, role == "assistant", calls.keys.sorted() == Array(0..<calls.count) else { throw Failure.incompleteResponse }
        let rows = (0..<calls.count).map { index -> [String: Any] in
            let call = calls[index]!
            return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments.joined()]]
        }
        let message: [String: Any] = ["role": "assistant", "content": text.joined(), "reasoning": reasoning, "tool_calls": rows]
        return ChatStream(object: ["id": id, "model": model, "choices": [["index": 0, "message": message, "finish_reason": finish]], "usage": usage ?? NSNull()],
                          text: text, arguments: (0..<calls.count).map { calls[$0]!.arguments }, correctionEligible: correctionEligible,
                          envelopeShapeValid: envelopeShapeValid, unambiguousJSON: unambiguousJSON, streamShapeAndUsageValid: streamShapeAndUsageValid,
                          envelopeRejection: envelopeRejection, jsonRejection: jsonRejection)
    }

    /// An admitted streaming request that received an upstream 429 terminates with
    /// the Responses failure event the engine understands. Never emit output items
    /// or invent usage, quota, or provider retry instructions for this failure.
    static func encodeRateLimitFailure(request: Request,
                                       failure: APIProviderHTTPClient.Failure = .rateLimited) throws -> Data {
        guard request.stream, failure == .rateLimited || failure == .providerBusy else { throw Failure.invalidRequest }
        var failed = response(id: "resp_" + UUID().uuidString, request: request, output: [], text: "", usage: NSNull())
        failed["status"] = "failed"
        failed["error"] = ["code": "rate_limit_exceeded", "message": failure.localizedDescription]
        var initial = failed
        initial["status"] = "in_progress"; initial["completed_at"] = NSNull(); initial["error"] = NSNull(); initial["end_turn"] = false
        var result = Data()
        for (sequence, event) in [("response.created", initial), ("response.in_progress", initial), ("response.failed", failed)].enumerated() {
            result.append(Data("event: \(event.0)\ndata: ".utf8))
            result.append(try json(["type": event.0, "sequence_number": sequence, "response": event.1]))
            result.append(Data("\n\n".utf8))
        }
        result.append(Data("data: [DONE]\n\n".utf8))
        return result
    }

    static func encode(_ reply: Reply, stream: Bool) throws -> Data {
        if !stream { return try json(reply.response) }
        var result = Data(), sequence = 0
        func emit(_ type: String, _ values: [String: Any]) throws {
            var object = values; object["type"] = type; object["sequence_number"] = sequence; sequence += 1
            result.append(Data("event: \(type)\ndata: ".utf8)); result.append(try json(object)); result.append(Data("\n\n".utf8))
        }
        var initial = reply.response; initial["status"] = "in_progress"; initial["output"] = []; initial["output_text"] = ""; initial["completed_at"] = NSNull(); initial["usage"] = NSNull(); initial["end_turn"] = false
        try emit("response.created", ["response": initial]); try emit("response.in_progress", ["response": initial])
        var toolIndex = 0
        for (index, item) in (reply.response["output"] as! [[String: Any]]).enumerated() {
            let type = item["type"] as! String, id = item["id"] as! String
            var pending = item
            pending["status"] = "in_progress"
            if type == "reasoning" { pending["summary"] = [] }
            if type == "message" { pending["content"] = [] }
            if type == "function_call" { pending["arguments"] = "" }
            if type == "custom_tool_call" { pending["input"] = "" }
            try emit("response.output_item.added", ["output_index": index, "item": pending])
            if type == "message" {
                let text = (item["content"] as! [[String: Any]]).compactMap { $0["text"] as? String }.joined()
                let part: [String: Any] = ["type": "output_text", "text": "", "annotations": []]
                let context: [String: Any] = ["item_id": id, "output_index": index, "content_index": 0]
                try emit("response.content_part.added", context.merging(["part": part]) { _, new in new })
                let chunks = reply.textDeltas.joined() == text ? reply.textDeltas : [text]
                for delta in chunks { try emit("response.output_text.delta", context.merging(["delta": delta]) { _, new in new }) }
                try emit("response.output_text.done", context.merging(["text": text]) { _, new in new })
                try emit("response.content_part.done", context.merging(["part": ["type": "output_text", "text": text, "annotations": []]]) { _, new in new })
            } else if type == "reasoning" {
                for (summaryIndex, part) in (item["summary"] as? [[String: Any]] ?? []).enumerated() {
                    let text = part["text"] as! String
                    let context: [String: Any] = ["item_id": id, "output_index": index, "summary_index": summaryIndex]
                    try emit("response.reasoning_summary_part.added", context.merging(["part": ["type": "summary_text", "text": ""]]) { _, new in new })
                    try emit("response.reasoning_summary_text.delta", context.merging(["delta": text]) { _, new in new })
                    try emit("response.reasoning_summary_text.done", context.merging(["text": text]) { _, new in new })
                    try emit("response.reasoning_summary_part.done", context.merging(["part": part]) { _, new in new })
                }
            } else if type == "function_call" || type == "custom_tool_call" {
                let custom = type == "custom_tool_call", field = custom ? "input" : "arguments", value = item[field] as! String
                let event = custom ? "response.custom_tool_call_input" : "response.function_call_arguments"
                let deltas = !custom && reply.argumentDeltas.indices.contains(toolIndex) && reply.argumentDeltas[toolIndex].joined() == value ? reply.argumentDeltas[toolIndex] : [value]
                for delta in deltas { try emit(event + ".delta", ["item_id": id, "output_index": index, "delta": delta]) }
                try emit(event + ".done", ["item_id": id, "output_index": index, field: value]); toolIndex += 1
            }
            try emit("response.output_item.done", ["output_index": index, "item": item])
        }
        try emit("response.completed", ["response": reply.response])
        result.append(Data("data: [DONE]\n\n".utf8))
        return result
    }

    /// Observational only: compare decoded provider text with the exact bytes emitted
    /// to the native Responses client. Failure or a budget miss omits the diagnostic.
    /// No string, hash, reasoning, request content or upstream identifier is emitted.
    static func finalTextDiagnostic(_ reply: Reply, encoded: Data, stream: Bool) -> FinalTextDiagnostic? {
        guard let source = reply.finalTextSource,
              let decoded = finalMessageText(reply.response), textShape(decoded) == source.decoded,
              let responseID = reply.response["id"] as? String,
              responseID.range(of: #"^resp_[A-Fa-f0-9-]{32,36}$"#, options: .regularExpression) != nil,
              let modelID = reply.response["model"] as? String,
              let identity = APIProviderCatalog.identity(for: modelID),
              encoded.count <= APIProviderHTTPClient.maximumResponseBytes else { return nil }
        let serialized: String, deltas: String?, completed: String?
        if stream {
            guard let wire = String(data: encoded, encoding: .utf8) else { return nil }
            let events = wire.components(separatedBy: "\n\n")
            guard events.count <= 4_096,
                  let output = reply.response["output"] as? [[String: Any]],
                  let messageID = output.first(where: { $0["type"] as? String == "message" })?["id"] as? String else { return nil }
            var message: String?, terminal: String?, fragments = "", fragmentBytes = 0
            for event in events {
                let lines = event.components(separatedBy: "\n")
                guard let header = lines.first, header.hasPrefix("event: ") else { continue }
                let type = String(header.dropFirst(7))
                guard ["response.output_text.delta", "response.output_item.done", "response.completed"].contains(type) else { continue }
                guard lines.count == 2, lines[1].hasPrefix("data: "),
                      let row = (try? JSONSerialization.jsonObject(with: Data(lines[1].dropFirst(6).utf8))) as? [String: Any],
                      row["type"] as? String == type else { return nil }
                switch type {
                case "response.output_text.delta":
                    guard row["item_id"] as? String == messageID, let delta = row["delta"] as? String else { return nil }
                    fragmentBytes += delta.utf8.count
                    guard fragmentBytes <= maximumText else { return nil }; fragments += delta
                case "response.output_item.done":
                    guard let item = row["item"] as? [String: Any] else { return nil }
                    if item["type"] as? String == "message" {
                        guard message == nil, item["id"] as? String == messageID,
                              let value = assistantMessageText(item) else { return nil }; message = value
                    } else if item["type"] as? String != "reasoning" { return nil }
                default:
                    guard terminal == nil, let resource = row["response"] as? [String: Any],
                          resource["id"] as? String == responseID, resource["model"] as? String == modelID,
                          let value = finalMessageText(resource) else { return nil }; terminal = value
                }
            }
            guard let message, let terminal else { return nil }
            serialized = message; deltas = fragments; completed = terminal
        } else {
            guard let resource = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any],
                  resource["id"] as? String == responseID, resource["model"] as? String == modelID,
                  let value = finalMessageText(resource) else { return nil }
            serialized = value; deltas = nil; completed = nil
        }
        guard let serializedShape = textShape(serialized) else { return nil }
        return FinalTextDiagnostic(kind: "api_final_text_v1", responseID: responseID, modelID: modelID,
            providerID: identity.providerID, upstream: source.upstream, decoded: source.decoded, serialized: serializedShape,
            upstreamMatchesDecoded: source.upstreamMatchesDecoded,
            decodedMatchesSerialized: decoded.utf8.elementsEqual(serialized.utf8),
            streamDeltasMatchSerialized: deltas.map { $0.utf8.elementsEqual(serialized.utf8) },
            completedMatchesSerialized: completed.map { $0.utf8.elementsEqual(serialized.utf8) })
    }
    private static func finalTextSource(_ upstream: String, response: [String: Any]) -> FinalTextSource? {
        guard !upstream.isEmpty, let decoded = finalMessageText(response),
              let sourceShape = textShape(upstream), let decodedShape = textShape(decoded) else { return nil }
        return FinalTextSource(upstream: sourceShape, decoded: decodedShape,
                               upstreamMatchesDecoded: upstream.utf8.elementsEqual(decoded.utf8))
    }
    private static func textShape(_ text: String) -> TextShape? {
        let bytes = text.utf8.count
        guard bytes <= maximumText else { return nil }
        var count = 0, minus = 0, nonBreaking = 0
        for scalar in text.unicodeScalars {
            count += 1
            if scalar.value == 0x2D { minus += 1 }
            if scalar.value == 0x2011 { nonBreaking += 1 }
        }
        return TextShape(utf8Bytes: bytes, unicodeScalars: count, hyphenMinusCount: minus, nonBreakingHyphenCount: nonBreaking)
    }
    private static func finalMessageText(_ resource: [String: Any]) -> String? {
        guard resource["status"] as? String == "completed", strictBool(resource["end_turn"]) == true,
              let output = resource["output"] as? [[String: Any]],
              output.allSatisfy({ ["message", "reasoning"].contains($0["type"] as? String ?? "") }) else { return nil }
        let messages = output.filter { $0["type"] as? String == "message" }
        guard messages.count == 1 else { return nil }
        return assistantMessageText(messages[0])
    }
    private static func assistantMessageText(_ item: [String: Any]) -> String? {
        guard item["type"] as? String == "message", item["role"] as? String == "assistant",
              item["status"] as? String == "completed", let parts = item["content"] as? [[String: Any]],
              !parts.isEmpty, parts.allSatisfy({ $0["type"] as? String == "output_text" && $0["text"] is String }) else { return nil }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    private static func response(id: String, request: Request, output: [[String: Any]], text: String, usage: Any) -> [String: Any] {
        var result = request.responseConfiguration
        result.merge(["id": id, "object": "response", "created_at": Int(Date().timeIntervalSince1970), "completed_at": Int(Date().timeIntervalSince1970), "status": "completed", "model": request.localModelID, "output": output, "output_text": text, "error": NSNull(), "incomplete_details": NSNull(), "usage": usage, "end_turn": !output.contains { ["function_call", "custom_tool_call"].contains($0["type"] as? String ?? "") }]) { _, value in value }
        return result
    }
    private static func usage(_ value: Any?, responses: Bool, observe: InvalidResponseObserver? = nil) throws -> Any {
        if absent(value) { return NSNull() }
        guard let usage = value as? [String: Any] else { throw invalidResponse(.usageObject, observe) }
        let input = try responseInteger(usage[responses ? "input_tokens" : "prompt_tokens"], default: -1, range: 0...100_000_000, guardID: .usageInputTokens, observe: observe)
        let output = try responseInteger(usage[responses ? "output_tokens" : "completion_tokens"], default: -1, range: 0...100_000_000, guardID: .usageOutputTokens, observe: observe)
        let total = try responseInteger(usage["total_tokens"], default: input + output, range: 0...200_000_000, guardID: .usageTotalTokens, observe: observe)
        guard total == input + output else { throw invalidResponse(.usageTotalConsistency, observe) }
        let outputDetailValue = usage[responses ? "output_tokens_details" : "completion_tokens_details"]
        guard absent(outputDetailValue) || outputDetailValue is [String: Any] else { throw invalidResponse(.usageOutputDetails, observe) }
        let details = outputDetailValue as? [String: Any]
        let reasoning = try responseInteger(details?["reasoning_tokens"], default: 0, range: 0...output, guardID: .usageReasoningTokens, observe: observe)
        let inputDetailValue = usage[responses ? "input_tokens_details" : "prompt_tokens_details"]
        guard absent(inputDetailValue) || inputDetailValue is [String: Any] else { throw invalidResponse(.usageInputDetails, observe) }
        let inputDetails = inputDetailValue as? [String: Any]
        let cached = try responseInteger(inputDetails?["cached_tokens"], default: 0, range: 0...input, guardID: .usageCachedTokens, observe: observe)
        return ["input_tokens": input, "output_tokens": output, "total_tokens": total, "input_tokens_details": ["cached_tokens": cached], "output_tokens_details": ["reasoning_tokens": reasoning]]
    }
    static func correctionUsage(_ normalized: Any?) -> APIModelCorrectionUsage? {
        guard let value = normalized as? [String: Any], let input = value["input_tokens"] as? Int,
              let output = value["output_tokens"] as? Int, let total = value["total_tokens"] as? Int,
              let inputDetails = value["input_tokens_details"] as? [String: Any], let cached = inputDetails["cached_tokens"] as? Int,
              let outputDetails = value["output_tokens_details"] as? [String: Any], let reasoning = outputDetails["reasoning_tokens"] as? Int else { return nil }
        return .init(inputTokens: input, outputTokens: output, totalTokens: total,
                     cachedInputTokens: cached, reasoningOutputTokens: reasoning)
    }
    static func withCorrectionMetadata(_ reply: Reply, ticket: APIModelCorrectionAccounting.Ticket,
                                       secondUsage: APIModelCorrectionUsage?) throws -> Reply {
        let combined = try secondUsage.map { try ticket.firstUsage.adding($0) } ?? ticket.firstUsage
        var response = reply.response
        // Standard usage remains the accepted response ONLY. The pinned engine
        // uses it for context occupancy; summed attempts would trigger compaction.
        response["x_computa_correction"] = ["version": 1, "correction_id": ticket.id.uuidString.lowercased(),
            "recovered": true, "attempt_count": 2, "context_usage": "accepted_response_only",
            "billable_usage_complete": secondUsage != nil, "second_usage_unknown": secondUsage == nil,
            "known_billable_usage": combined.responseUsage]
        return Reply(response: response, textDeltas: reply.textDeltas, argumentDeltas: reply.argumentDeltas,
                     finalTextSource: reply.finalTextSource)
    }

    private static func validatedArguments(_ text: String, tool: Tool,
                                           onRejection: ((ArgumentValidationDiagnostic.Reason) -> Void)? = nil,
                                           onSchemaMismatch: ((SchemaViolation) -> Void)? = nil) throws -> [String: Any] {
        guard text.utf8.count <= maximumText, let data = text.data(using: .utf8) else {
            onRejection?(.oversized); throw Failure.invalidArguments
        }
        guard let value = try? JSONSerialization.jsonObject(with: data) else {
            onRejection?(.invalidJSON); throw Failure.invalidArguments
        }
        guard let object = value as? [String: Any] else {
            onRejection?(.nonObject); throw Failure.invalidArguments
        }
        guard matches(object, schema: tool.schema, root: tool.schema, depth: 0) else {
            if let onSchemaMismatch {
                var nodes = 0
                onSchemaMismatch(localizeSchemaFailure(object, schema: tool.schema, depth: 0, path: [], nodes: &nodes)
                    ?? .init(constraint: .schemaMismatch, path: []))
            }
            onRejection?(.schemaMismatch); throw Failure.invalidArguments
        }
        return object
    }

    /// Saved native threads retain their original dynamic schemas. Completed
    /// browser calls can therefore precede or follow the assertion upgrade in
    /// either catalog. Only history accepts these two exact shapes; new replies
    /// still use validatedArguments with the strict current callable schema.
    private static func validateHistoricalArguments(_ text: String, tool: Tool) throws {
        guard !tool.custom,
              let variants = ComputaModelToolCatalog.browserMutationSchemaVariants(
                name: tool.name, namespace: tool.namespace, schema: tool.schema) else {
            _ = try validatedArguments(text, tool: tool)
            return
        }
        let historyTool = Tool(name: tool.name, namespace: tool.namespace, wireName: tool.wireName,
            custom: false, schema: ["oneOf": [variants.legacy, variants.current]], description: tool.description)
        _ = try validatedArguments(text, tool: historyTool)
    }
    /// Observational localization after the authoritative matches() has refused
    /// the arguments. It never accepts anything. References/composition and any
    /// uncertain or exhausted traversal retain a generic schema mismatch.
    private static func localizeSchemaFailure(_ value: Any, schema: [String: Any], depth: Int,
                                             path: [SchemaPathPart], nodes: inout Int) -> SchemaViolation? {
        nodes += 1
        guard depth <= 32, nodes <= 256, path.count <= 8 else { return .init(constraint: .schemaMismatch, path: []) }
        if schema["$ref"] != nil || ["anyOf","oneOf","allOf"].contains(where: { schema[$0] != nil }) { return .init(constraint: .schemaMismatch, path: []) }
        if value is NSNull, strictBool(schema["nullable"]) == true { return nil }
        if let type = schema["type"] {
            let types = (type as? String).map { [$0] } ?? (type as? [String]) ?? []
            if !types.contains(where: { typeMatches(value, type: $0) }) { return .init(constraint: .typeMismatch, path: path) }
        }
        if schema["enum"] != nil { return .init(constraint: .schemaMismatch, path: []) }
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            let required = schema["required"] as? [String] ?? []
            guard object.count <= 256, properties.count <= 256, required.count <= 256 else { return .init(constraint: .schemaMismatch, path: []) }
            for name in required.sorted() where object[name] == nil {
                guard properties[name] != nil, name.utf8.count <= 128, path.count < 8 else { return .init(constraint: .schemaMismatch, path: []) }
                return .init(constraint: .missingRequired, path: path + [.property(name)])
            }
            for name in properties.keys.sorted() {
                guard let child = object[name] else { continue }
                guard name.utf8.count <= 128, path.count < 8 else { return .init(constraint: .schemaMismatch, path: []) }
                if let failure = localizeSchemaFailure(child, schema: properties[name]!, depth: depth + 1, path: path + [.property(name)], nodes: &nodes) { return failure }
            }
            if strictBool(schema["additionalProperties"]) == false && object.keys.contains(where: { properties[$0] == nil }) { return .init(constraint: .unexpectedFields, path: path) }
        }
        if let array = value as? [Any] {
            guard array.count <= 256 else { return .init(constraint: .schemaMismatch, path: []) }
            if let min = schema["minItems"] as? Int, array.count < min { return .init(constraint: .arrayBounds, path: path) }
            if let max = schema["maxItems"] as? Int, array.count > max { return .init(constraint: .arrayBounds, path: path) }
            if let item = schema["items"] as? [String: Any] {
                guard path.count < 8 else { return .init(constraint: .schemaMismatch, path: []) }
                for child in array {
                    if let failure = localizeSchemaFailure(child, schema: item, depth: depth + 1, path: path + [.items], nodes: &nodes) { return failure }
                }
            }
        }
        return nil
    }
    // The gateway validates the schema subset emitted by the pinned native tools.
    // Unsupported constraints are rejected, never silently treated as permissive.
    private static func checkSchema(_ schema: [String: Any], depth: Int = 0) throws {
        guard depth <= 32 else { throw Failure.invalidTool }
        let supported: Set<String> = ["type", "properties", "required", "additionalProperties", "items", "enum", "const", "anyOf", "oneOf", "allOf", "$ref", "$defs", "definitions", "description", "title", "default", "examples", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength", "minItems", "maxItems", "pattern", "format", "nullable"]
        guard Set(schema.keys).isSubset(of: supported) else { throw Failure.invalidTool }
        if let types = schema["type"] {
            let list = (types as? String).map { [$0] } ?? (types as? [String]) ?? []
            guard !list.isEmpty, Set(list).isSubset(of: ["object", "array", "string", "number", "integer", "boolean", "null"]) else { throw Failure.invalidTool }
        }
        for key in ["description", "title", "pattern", "format", "$ref"] where schema[key] != nil {
            guard schema[key] is String else { throw Failure.invalidTool }
        }
        for key in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] where schema[key] != nil {
            guard let n = schema[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw Failure.invalidTool }
        }
        for key in ["minLength", "maxLength", "minItems", "maxItems"] where schema[key] != nil {
            guard let n = schema[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 0, n.doubleValue <= 10_000_000,
                  n.doubleValue.rounded(.towardZero) == n.doubleValue else { throw Failure.invalidTool }
        }
        if schema["nullable"] != nil, strictBool(schema["nullable"]) == nil { throw Failure.invalidTool }
        if schema["enum"] != nil { guard let values = schema["enum"] as? [Any], !values.isEmpty else { throw Failure.invalidTool } }
        if schema["examples"] != nil, !(schema["examples"] is [Any]) { throw Failure.invalidTool }
        if let format = schema["format"] as? String { guard ["uri", "uuid", "date-time"].contains(format) else { throw Failure.invalidTool } }
        if let ref = schema["$ref"] as? String { guard ref.hasPrefix("#/$defs/") || ref.hasPrefix("#/definitions/"), ref.split(separator: "/").count == 3 else { throw Failure.invalidTool } }
        for key in ["properties", "$defs", "definitions"] {
            if let children = schema[key] as? [String: [String: Any]] { for child in children.values { try checkSchema(child, depth: depth + 1) } }
            else if schema[key] != nil { throw Failure.invalidTool }
        }
        for key in ["anyOf", "oneOf", "allOf"] {
            if let children = schema[key] as? [[String: Any]], !children.isEmpty, children.count <= 32 { for child in children { try checkSchema(child, depth: depth + 1) } }
            else if schema[key] != nil { throw Failure.invalidTool }
        }
        for key in ["items", "additionalProperties"] {
            if let child = schema[key] as? [String: Any] { try checkSchema(child, depth: depth + 1) }
            else if key == "items" && schema[key] != nil || key == "additionalProperties" && schema[key] != nil && strictBool(schema[key]) == nil { throw Failure.invalidTool }
        }
        if let required = schema["required"] as? [String] { guard Set(required).count == required.count else { throw Failure.invalidTool } }
        else if schema["required"] != nil { throw Failure.invalidTool }
        if let pattern = schema["pattern"] as? String { guard pattern.utf8.count <= 1_024, (try? NSRegularExpression(pattern: pattern)) != nil else { throw Failure.invalidTool } }
    }
    private static func matches(_ value: Any, schema: [String: Any], root: [String: Any], depth: Int) -> Bool {
        guard depth <= 32 else { return false }
        if let ref = schema["$ref"] as? String {
            let pieces = ref.split(separator: "/").map(String.init)
            guard pieces.count == 3, let child = (root[pieces[1]] as? [String: [String: Any]])?[pieces[2]], matches(value, schema: child, root: root, depth: depth + 1) else { return false }
        }
        if value is NSNull, strictBool(schema["nullable"]) == true { return true }
        if let type = schema["type"] {
            let types = (type as? String).map { [$0] } ?? (type as? [String]) ?? []
            guard types.contains(where: { typeMatches(value, type: $0) }) else { return false }
        }
        if let constant = schema["const"], !equalJSON(value, constant) { return false }
        if let values = schema["enum"] as? [Any], !values.contains(where: { equalJSON(value, $0) }) { return false }
        for key in ["anyOf", "oneOf", "allOf"] {
            if let children = schema[key] as? [[String: Any]] {
                let count = children.filter { matches(value, schema: $0, root: root, depth: depth + 1) }.count
                if key == "anyOf" && count == 0 || key == "oneOf" && count != 1 || key == "allOf" && count != children.count { return false }
            }
        }
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            guard (schema["required"] as? [String] ?? []).allSatisfy({ object[$0] != nil }) else { return false }
            for (key, child) in object {
                if let spec = properties[key] { if !matches(child, schema: spec, root: root, depth: depth + 1) { return false } }
                else if let spec = schema["additionalProperties"] as? [String: Any] { if !matches(child, schema: spec, root: root, depth: depth + 1) { return false } }
                else if strictBool(schema["additionalProperties"]) == false { return false }
            }
        }
        if let array = value as? [Any] {
            if let min = schema["minItems"] as? Int, array.count < min { return false }; if let max = schema["maxItems"] as? Int, array.count > max { return false }
            if let item = schema["items"] as? [String: Any], !array.allSatisfy({ matches($0, schema: item, root: root, depth: depth + 1) }) { return false }
        }
        if let string = value as? String {
            if let min = schema["minLength"] as? Int, string.unicodeScalars.count < min { return false }; if let max = schema["maxLength"] as? Int, string.unicodeScalars.count > max { return false }
            if let pattern = schema["pattern"] as? String, string.range(of: pattern, options: .regularExpression) == nil { return false }
            if let format = schema["format"] as? String {
                if format == "uri" && URL(string: string)?.scheme == nil || format == "uuid" && UUID(uuidString: string) == nil || format == "date-time" && ISO8601DateFormatter().date(from: string) == nil { return false }
            }
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let n = number.doubleValue
            for key in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] {
                if let bound = schema[key] as? NSNumber {
                    if key == "minimum" && n < bound.doubleValue || key == "maximum" && n > bound.doubleValue || key == "exclusiveMinimum" && n <= bound.doubleValue || key == "exclusiveMaximum" && n >= bound.doubleValue { return false }
                }
            }
        }
        return true
    }
    private static func typeMatches(_ value: Any, type: String) -> Bool {
        switch type {
        case "null": return value is NSNull
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "boolean": return strictBool(value) != nil
        case "number", "integer":
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return false }
            return type == "number" || n.doubleValue.rounded(.towardZero) == n.doubleValue
        default: return false
        }
    }
    private static func equalJSON(_ lhs: Any, _ rhs: Any) -> Bool { (try? JSONSerialization.data(withJSONObject: lhs, options: [.fragmentsAllowed, .sortedKeys])) == (try? JSONSerialization.data(withJSONObject: rhs, options: [.fragmentsAllowed, .sortedKeys])) }
    private static func validName(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 && value.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil }
    private static func validCallID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    private static func absent(_ value: Any?) -> Bool { value == nil || value is NSNull }
    private static func strictBool(_ value: Any?) -> Bool? { guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }; return n.boolValue }
    private static func boolean(_ value: Any?, default fallback: Bool) throws -> Bool { if absent(value) { return fallback }; guard let b = strictBool(value) else { throw Failure.invalidRequest }; return b }
    private static func integer(_ value: Any?, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        if absent(value) { guard range.contains(fallback) else { throw Failure.invalidResponse }; return fallback }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue == Double(n.intValue), range.contains(n.intValue) else { throw Failure.invalidResponse }; return n.intValue
    }
    private static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
}

/// A provider's private reasoning is never mislabeled as a visible summary. The native
/// Responses history stores only authenticated ciphertext, bound to this native thread and model.
struct APIReasoningCapsules: Sendable {
    struct Payload: Codable, Sendable {
        let reasoning: String?
        let callIDs: [String]
        let responseID: String
        var remoteEncryptedContent: String? = nil
        var remoteItemID: String? = nil
        var toolNaming: String? = nil
    }
    let key: Data
    init(key: Data) throws { guard key.count == 32 else { throw APIModelResponseCodec.Failure.invalidReasoning }; self.key = key }
    static func persistent() throws -> Self {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.ahmedelamin.Computa.api-reasoning-v1", kSecAttrAccount as String: "aes256-gcm", kSecAttrSynchronizable as String: false]
        var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return try Self(key: data) }
        guard status == errSecItemNotFound else { throw APIModelResponseCodec.Failure.invalidReasoning }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecDuplicateItem { return try persistent() }
        guard added == errSecSuccess else { throw APIModelResponseCodec.Failure.invalidReasoning }
        return try Self(key: data)
    }
    private func context(itemID: String, providerID: String, modelID: String, baseURL: URL, threadID: String) throws -> Data {
        guard let task = UUID(uuidString: threadID) else { throw APIModelResponseCodec.Failure.invalidReasoning }
        return try JSONSerialization.data(withJSONObject: ["version": "1", "item": itemID, "provider": providerID, "model": modelID, "baseURL": baseURL.absoluteString, "thread": task.uuidString.lowercased()], options: [.sortedKeys])
    }
    static func validatePayload(_ payload: Payload) throws {
        guard try JSONEncoder().encode(payload).count <= 2_000_000 else { throw APIModelResponseCodec.Failure.invalidReasoning }
    }
    func seal(_ payload: Payload, itemID: String, providerID: String, modelID: String, baseURL: URL, threadID: String) throws -> String {
        try Self.validatePayload(payload)
        let data = try JSONEncoder().encode(payload)
        let box = try AES.GCM.seal(data, using: SymmetricKey(data: key), authenticating: context(itemID: itemID, providerID: providerID, modelID: modelID, baseURL: baseURL, threadID: threadID))
        guard let combined = box.combined else { throw APIModelResponseCodec.Failure.invalidReasoning }
        return "computa-api-reasoning-v1:" + combined.base64EncodedString()
    }
    func open(_ value: String, itemID: String, providerID: String, modelID: String, baseURL: URL, threadID: String) throws -> Payload {
        do {
            let prefix = "computa-api-reasoning-v1:"
            guard value.hasPrefix(prefix), value.utf8.count <= 2_700_000, let data = Data(base64Encoded: String(value.dropFirst(prefix.count))) else { throw APIModelResponseCodec.Failure.invalidReasoning }
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key), authenticating: context(itemID: itemID, providerID: providerID, modelID: modelID, baseURL: baseURL, threadID: threadID))
            return try JSONDecoder().decode(Payload.self, from: plain)
        } catch { throw APIModelResponseCodec.Failure.invalidReasoning }
    }
}

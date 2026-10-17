import Foundation
import CoreFoundation

/// The browser is a model transport. It never owns a tool or executes
/// an action: validated function calls return to the existing App Server loop.
enum WebModelResponseCodec {
    static let maximumPromptBytes = 160 * 1_024

    struct Request: Sendable {
        let model: String
        let singleActionRelay: Bool
        let stream: Bool
        let prompt: String
        let runtimeInstructions: String
        let currentUserInstructions: String
        let offeredToolNames: Set<String>
        let customToolNames: Set<String>
        fileprivate let tools: [String: OfferedTool]
        fileprivate let toolPolicy: ToolPolicy
        fileprivate let parallelToolCalls: Bool
        fileprivate let maximumToolCalls: Int?
        /// Serialized storage keeps the request safely transferable across the
        /// server actor while preserving the standard response configuration.
        fileprivate let responseConfiguration: Data
        /// Private, lossless admission input, before presentation-only tool
        /// filtering. Continuations must also reject changes to hidden tools.
        let continuationRequest: Data
    }

    fileprivate struct OfferedTool: Sendable {
        let name: String
        let namespace: String?
        let isCustom: Bool
    }

    fileprivate struct ToolPolicy: Sendable {
        let allowedNames: Set<String>
        let requiresCall: Bool
    }

    enum AssistantPhase: String, Equatable, Sendable {
        case commentary
        case finalAnswer = "final_answer"
    }

    struct ToolCall: Equatable, Sendable {
        let name: String
        let argumentsJSON: String
        let namespace: String?
        var customInput: String? = nil
    }

    enum Reply: Equatable, Sendable {
        case message(String)
        case assistantMessage(String, phase: AssistantPhase)
        case toolCalls([ToolCall])
        case toolCallsWithCommentary([ToolCall], String)
    }

    /// Content-free diagnostics for a reply already rejected by the parser.
    /// Only finite classifications and scalar measurements may leave this type;
    /// reply text, JSON keys, tool names and arguments are never retained.
    struct MalformedEnvelopeDiagnostic: Codable, Equatable, Sendable {
        enum Reason: String, Codable, CaseIterable, Sendable {
            case invalidJSON = "invalid_json"
            case notObject = "not_object"
            case missingOrUnknownType = "missing_or_unknown_type"
            case invalidMessageText = "invalid_message_text"
            case invalidCalls = "invalid_calls"
            case invalidCallName = "invalid_call_name"
            case invalidEnvelopeFields = "invalid_envelope_fields"
            case invalidMessagePhase = "invalid_message_phase"
            case invalidToolCommentary = "invalid_tool_commentary"
        }

        let reason: Reason
        let utf8Bytes: Int
        /// True only when the existing parser removed a supported JSON fence.
        let fenced: Bool
    }

    enum Modality: String, Equatable, Sendable {
        case image
        case audio
        case file
        case video
    }

    enum Failure: LocalizedError, Equatable {
        case invalidRequest
        case missingModel
        case missingInput
        case previousResponseUnsupported
        case invalidTools
        case unsupportedToolType
        case unsupportedModality(Modality)
        case promptTooLarge(actualBytes: Int, maximumBytes: Int)
        case emptyReply
        case malformedEnvelope
        case unknownTool(String)
        case argumentsMustBeObject
        case customInputMustBeString
        case invalidParameter(String)
        case unsupportedParameter(String)
        case invalidToolChoice
        case rejectedToolChoice
        case parallelToolCallsUnsupported
        case toolCallLimitExceeded

        var errorDescription: String? {
            switch self {
            case .invalidRequest: "The web model request must be a UTF-8 JSON object."
            case .missingModel: "The web model request needs a nonempty model name."
            case .missingInput: "The web model request needs input as a string or an array."
            case .previousResponseUnsupported:
                "Web models need the complete local conversation in input; previous_response_id is unsupported."
            case .invalidTools: "The web model request contains an invalid or ambiguous tool definition."
            case .unsupportedToolType:
                "Web models support function tools with JSON object arguments and custom tools with literal string input, including namespaces. This request contains an unsupported tool type."
            case .unsupportedModality(.image):
                "Browser models cannot receive image attachments yet. Use a text or accessibility observation, or a model that supports images. No prompt was submitted."
            case .unsupportedModality(.audio):
                "Browser models cannot receive audio attachments yet. Provide a transcript or use a model that supports audio. No prompt was submitted."
            case .unsupportedModality(.file), .unsupportedModality(.video):
                "Browser models support text input only. Read the attachment through the local tools first. No prompt was submitted."
            case let .promptTooLarge(actual, maximum):
                "The complete web model prompt is \(actual) bytes, exceeding the \(maximum)-byte limit. No context was truncated or submitted."
            case .emptyReply: "The website returned an empty model reply."
            case .malformedEnvelope: "The website returned a malformed model response envelope. No tool calls from this reply were dispatched."
            case .unknownTool: "The website requested an unoffered tool. No tool calls from this reply were dispatched."
            case .argumentsMustBeObject: "Web model tool arguments must be a JSON object. No tool calls from this reply were dispatched."
            case .customInputMustBeString: "A custom tool needs literal string input and no function arguments. No tool calls from this reply were dispatched."
            case let .invalidParameter(parameter): "The web model request contains an invalid \(parameter) parameter. No prompt was submitted."
            case let .unsupportedParameter(parameter): "Browser models do not support the requested \(parameter) setting. No prompt was submitted."
            case .invalidToolChoice: "The requested tool_choice must identify currently offered tools and a supported selection mode. No prompt was submitted."
            case .rejectedToolChoice: "The website reply violated tool_choice. No tool calls from this reply were dispatched."
            case .parallelToolCallsUnsupported: "The website returned multiple calls when parallel_tool_calls was false. No tool calls from this reply were dispatched."
            case .toolCallLimitExceeded: "The website returned more calls than max_tool_calls allows. No tool calls from this reply were dispatched."
            }
        }
    }

    static func prepareRequest(_ data: Data) throws -> Request {
        // Reject before expanding a large JSON body into prompt storage.
        guard data.count <= maximumPromptBytes else {
            throw Failure.promptTooLarge(actualBytes: data.count, maximumBytes: maximumPromptBytes)
        }
        guard let originalJSON = String(data: data, encoding: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidRequest
        }
        guard let model = object["model"] as? String,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.missingModel
        }
        guard object["input"] is String || object["input"] is [Any] else {
            throw Failure.missingInput
        }
        if let items = object["input"] as? [Any], items.contains(where: { !($0 is [String: Any]) }) {
            throw Failure.invalidParameter("input")
        }
        try rejectUnsupportedModalities(in: object["input"])
        if let previous = object["previous_response_id"], !(previous is NSNull) {
            throw Failure.previousResponseUnsupported
        }
        if let instructions = object["instructions"], !(instructions is String), !(instructions is NSNull) {
            throw Failure.invalidRequest
        }
        let schemas: [[String: Any]]
        var toolDefinitionsChanged = false
        if let raw = object["tools"], !(raw is NSNull) {
            guard let values = raw as? [[String: Any]] else { throw Failure.invalidTools }
            var historical: [String: OfferedTool] = [:]
            for value in values {
                if value["type"] as? String == "namespace" {
                    guard let namespace = value["name"] as? String, !namespace.isEmpty,
                          let children = value["tools"] as? [[String: Any]] else { throw Failure.invalidTools }
                    for child in children { try insertTool(child, namespace: namespace, into: &historical) }
                } else { try insertTool(value, namespace: nil, into: &historical) }
            }
            schemas = ComputaModelToolCatalog.visibleToolDefinitions(values, modelID: model)
            toolDefinitionsChanged = !NSArray(array: values).isEqual(to: schemas)
            object["tools"] = schemas
        } else {
            schemas = []
        }
        var offered: [String: OfferedTool] = [:]
        for schema in schemas {
            if schema["type"] as? String == "namespace" {
                guard let namespace = schema["name"] as? String, !namespace.isEmpty,
                      let children = schema["tools"] as? [[String: Any]] else { throw Failure.invalidTools }
                for child in children { try insertTool(child, namespace: namespace, into: &offered) }
            } else {
                try insertTool(schema, namespace: nil, into: &offered)
            }
        }
        let stream = try booleanParameter("stream", in: object, defaultValue: false, nullable: false)
        let parallel = try booleanParameter("parallel_tool_calls", in: object, defaultValue: true)
        let policy = try toolPolicy(object["tool_choice"], tools: offered)
        let configuration = try responseConfiguration(object, schemas: schemas, parallel: parallel)
        let customNames = Set(offered.filter { $0.value.isCustom }.keys)
        let includedInstructionText = trustedInstructionText(in: object)
        let runtimeInstructions = ComputaAgentInstructions.webInferenceContract(offeredFunctions: offered.mapValues(\.name),
            customToolNames: customNames, includedInstructionText: includedInstructionText)
        let latestUserItemIndex = (object["input"] as? [Any])?.lastIndex { item in
            guard let message = item as? [String: Any], message["role"] as? String == "user" else { return false }
            return message["type"] == nil || message["type"] as? String == "message"
        }
        let currentUserInstructions = ComputaAgentInstructions.webCurrentUserContract(
            latestUserItemIndex: latestUserItemIndex, inputIsString: object["input"] is String)
        let displaySource = toolDefinitionsChanged
            ? String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            : originalJSON
        let isChatGPT = LocalModelCatalog.webProvider(for: model) == "chatgpt"
        let displayJSON = displayStableJSON(displaySource, shieldURLPunctuation: isChatGPT)
        let prompt = """
        \(runtimeInstructions)

        \(ComputaAgentInstructions.webRequestContext)
        COMPLETE_RESPONSES_REQUEST_JSON:
        \(displayJSON)
        END_COMPLETE_RESPONSES_REQUEST_JSON.

        \(currentUserInstructions)

        \(ComputaAgentInstructions.webResponseContract(offeredToolNames: Array(offered.keys), customToolNames: customNames,
            includedInstructionText: includedInstructionText, responseFormat: .fencedJSON, singleActionRelay: isChatGPT))
        """
        let bytes = prompt.utf8.count
        guard bytes <= maximumPromptBytes else {
            throw Failure.promptTooLarge(actualBytes: bytes, maximumBytes: maximumPromptBytes)
        }
        return Request(model: model, singleActionRelay: isChatGPT, stream: stream, prompt: prompt, runtimeInstructions: runtimeInstructions,
                       currentUserInstructions: currentUserInstructions,
                       offeredToolNames: Set(offered.keys), customToolNames: customNames, tools: offered,
                       toolPolicy: policy, parallelToolCalls: parallel,
                       maximumToolCalls: (object["max_tool_calls"] as? NSNumber)?.intValue,
                       responseConfiguration: configuration, continuationRequest: data)
    }

    /// Only actual local instruction fields can establish an already-supplied
    /// complete contract block. Never promote quoted user/history/tool data or
    /// join separate parts into a match that no individual instruction contains.
    private static func trustedInstructionText(in object: [String: Any]) -> [String] {
        var texts = (object["instructions"] as? String).map { [$0] } ?? []
        for message in object["input"] as? [[String: Any]] ?? [] {
            guard message["type"] == nil || message["type"] as? String == "message",
                  let role = message["role"] as? String, ["system", "developer"].contains(role) else { continue }
            if let content = message["content"] as? String {
                texts.append(content)
            } else if let parts = message["content"] as? [[String: Any]] {
                for part in parts {
                    guard let type = part["type"] as? String, ["input_text", "text"].contains(type),
                          let text = part["text"] as? String else { continue }
                    texts.append(text)
                }
            }
        }
        return texts
    }

    /// Protect rendering-sensitive punctuation in JSON strings. ChatGPT's
    /// selected message DOM was observed changing the literal request after
    /// Send; shielding . : / is a mitigation hypothesis, not a parser diagnosis.
    /// Structural JSON punctuation and decoded values remain unchanged. Other
    /// providers retain literal URL punctuation. Consume complete escape pairs
    /// so quotes and literal backslashes retain their decoded values.
    private static func displayStableJSON(_ original: String, shieldURLPunctuation: Bool = false) -> String {
        var bytes = original.utf8.makeIterator()
        var result: [UInt8] = []
        result.reserveCapacity(original.utf8.count)
        let hex = Array("0123456789abcdef".utf8)
        var inString = false
        func appendUnicodeEscape(_ byte: UInt8) {
            result.append(contentsOf: [92, 117, 48, 48, hex[Int(byte >> 4)], hex[Int(byte & 15)]])
        }
        while let byte = bytes.next() {
            if !inString {
                result.append(byte)
                if byte == 34 { inString = true }
                continue
            }
            if byte == 34 {
                result.append(byte)
                inString = false
                continue
            }
            if byte == 92, let escaped = bytes.next() {
                if escaped == 47 {
                    if shieldURLPunctuation { appendUnicodeEscape(escaped) }
                    else { result.append(escaped) }
                }
                else if escaped == 34 || escaped == 92 { appendUnicodeEscape(escaped) }
                else { result.append(byte); result.append(escaped) }
            } else if shieldURLPunctuation && [46, 47, 58].contains(byte)
                        || (33...44).contains(byte) || (59...64).contains(byte)
                        || (91...96).contains(byte) || (123...126).contains(byte) {
                appendUnicodeEscape(byte)
            } else {
                result.append(byte)
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Website prose is a final message, never an action. JSON-shaped output
    /// and code fences must satisfy the complete envelope contract; do
    /// not extract or repair a call hidden inside surrounding prose.
    static func parseEmbeddedReply(_ text: String, request: Request) throws -> Reply {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyReply }
        if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "{}")) == nil,
           !trimmed.contains("```"), !trimmed.hasPrefix("["), !trimmed.hasPrefix("\"") {
            return try validated(.message(text), request: request)
        }
        return try parseReply(text, request: request, requireEnvelope: true)
    }

    static func malformedEmbeddedReplyDiagnostic(_ text: String, request: Request) -> MalformedEnvelopeDiagnostic? {
        do { _ = try parseEmbeddedReply(text, request: request); return nil }
        catch {
            guard (error as? Failure) == .malformedEnvelope else { return nil }
            return malformedEnvelopeDiagnostic(text, request: request, requireEnvelope: true)
        }
    }

    /// Generic callers keep ordinary-text compatibility. Strict envelope
    /// callers never repair or extract JSON.
    static func parseReply(_ text: String, request: Request, requireEnvelope: Bool = false) throws -> Reply {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyReply }
        let candidate = removingJSONFence(trimmed)
        guard let data = candidate.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A damaged tool envelope must never be presented as a successful
            // final answer. Ordinary prose/code/JSON still remains ordinary text.
            if requireEnvelope || looksLikeToolEnvelope(candidate) { throw Failure.malformedEnvelope }
            return try validated(.message(text), request: request)
        }
        switch envelope["type"] as? String {
        case "message":
            guard Set(envelope.keys).isSubset(of: ["type", "text", "phase"]),
                  let message = envelope["text"] as? String else { throw Failure.malformedEnvelope }
            if let rawPhase = envelope["phase"] {
                guard let value = rawPhase as? String, let phase = AssistantPhase(rawValue: value) else {
                    throw Failure.malformedEnvelope
                }
                return try validated(.assistantMessage(message, phase: phase), request: request)
            }
            return try validated(.message(message), request: request)
        case "tool_calls":
            guard Set(envelope.keys).isSubset(of: ["type", "calls", "commentary"]),
                  let calls = envelope["calls"] as? [[String: Any]], !calls.isEmpty else {
                throw Failure.malformedEnvelope
            }
            if let commentary = envelope["commentary"], !(commentary is String) {
                throw Failure.malformedEnvelope
            }
            let validated = try calls.map { call -> ToolCall in
                guard let offeredName = call["name"] as? String, !offeredName.isEmpty else {
                    throw Failure.malformedEnvelope
                }
                guard let tool = request.tools[offeredName] else { throw Failure.unknownTool(offeredName) }
                guard request.toolPolicy.allowedNames.contains(offeredName) else { throw Failure.rejectedToolChoice }
                if tool.isCustom {
                    guard Set(call.keys) == ["name", "input"], let input = call["input"] as? String else {
                        throw Failure.customInputMustBeString
                    }
                    return ToolCall(name: tool.name, argumentsJSON: "", namespace: tool.namespace, customInput: input)
                }
                guard Set(call.keys) == ["name", "arguments"], let arguments = call["arguments"] as? [String: Any] else {
                    throw Failure.argumentsMustBeObject
                }
                let encoded = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes])
                return ToolCall(name: tool.name, argumentsJSON: String(decoding: encoded, as: UTF8.self), namespace: tool.namespace)
            }
            let reply: Reply = if let commentary = envelope["commentary"] as? String {
                .toolCallsWithCommentary(validated, commentary)
            } else {
                .toolCalls(validated)
            }
            return try self.validated(reply, request: request)
        default:
            if requireEnvelope { throw Failure.malformedEnvelope }
            return try validated(.message(text), request: request)
        }
    }

    /// Diagnose exactly the existing malformed-envelope failure without
    /// changing acceptance, repairing JSON, or exposing provider response data.
    /// Other failures (including unoffered tools) keep their existing identity.
    static func malformedEnvelopeDiagnostic(_ text: String, request: Request,
                                            requireEnvelope: Bool = true) -> MalformedEnvelopeDiagnostic? {
        do {
            _ = try parseReply(text, request: request, requireEnvelope: requireEnvelope)
            return nil
        } catch {
            guard (error as? Failure) == .malformedEnvelope else { return nil }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = removingJSONFence(trimmed)
        let diagnostic: (MalformedEnvelopeDiagnostic.Reason) -> MalformedEnvelopeDiagnostic = {
            .init(reason: $0, utf8Bytes: text.utf8.count, fenced: candidate != trimmed)
        }
        // Fragments distinguish valid scalar/array JSON from invalid JSON for
        // diagnostics only. parseReply above remains the acceptance authority.
        guard let object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8), options: .fragmentsAllowed) else {
            return diagnostic(.invalidJSON)
        }
        guard let envelope = object as? [String: Any] else { return diagnostic(.notObject) }
        switch envelope["type"] as? String {
        case "message":
            guard Set(envelope.keys).isSubset(of: ["type", "text", "phase"]) else { return diagnostic(.invalidEnvelopeFields) }
            guard envelope["text"] is String else { return diagnostic(.invalidMessageText) }
            if let rawPhase = envelope["phase"], (rawPhase as? String).flatMap(AssistantPhase.init(rawValue:)) == nil {
                return diagnostic(.invalidMessagePhase)
            }
            return nil
        case "tool_calls":
            guard Set(envelope.keys).isSubset(of: ["type", "calls", "commentary"]) else { return diagnostic(.invalidEnvelopeFields) }
            if let commentary = envelope["commentary"], !(commentary is String) {
                return diagnostic(.invalidToolCommentary)
            }
            guard let calls = envelope["calls"] as? [[String: Any]], !calls.isEmpty else {
                return diagnostic(.invalidCalls)
            }
            if calls.contains(where: { ($0["name"] as? String)?.isEmpty != false }) {
                return diagnostic(.invalidCallName)
            }
            return nil
        default:
            return diagnostic(.missingOrUnknownType)
        }
    }

    /// All items are buffered from the website before this stream is emitted.
    /// Browser providers do not expose verified token counts, so usage is null.
    static func streamData(
        for reply: Reply,
        request: Request,
        responseID: String = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        createdAt: Int = Int(Date().timeIntervalSince1970),
        websiteModelEvidence: WebsiteModelEvidence? = nil,
        websiteToolSelection: String? = nil
    ) throws -> Data {
        _ = try validated(reply, request: request)
        let output = outputItems(for: reply, responseID: responseID)
        let initial = response(request: request, reply: reply, responseID: responseID, createdAt: createdAt, output: [], completed: false, websiteModelEvidence: websiteModelEvidence, websiteToolSelection: websiteToolSelection)
        var events: [[String: Any]] = [
            ["type": "response.created", "response": initial],
            ["type": "response.in_progress", "response": initial],
        ]
        for (index, item) in output.enumerated() {
            let id = item["id"] as! String
            if item["type"] as? String == "message" {
                let content = item["content"] as! [[String: Any]]
                let part = content[0]
                let text = part["text"] as! String
                var pending = item
                pending["status"] = "in_progress"
                pending["content"] = [] as [String]
                let common: [String: Any] = ["item_id": id, "output_index": index, "content_index": 0]
                events.append(["type": "response.output_item.added", "output_index": index, "item": pending])
                events.append(common.merging(["type": "response.content_part.added", "part": ["type": "output_text", "text": "", "annotations": [] as [String]]]) { _, new in new })
                events.append(common.merging(["type": "response.output_text.delta", "delta": text]) { _, new in new })
                events.append(common.merging(["type": "response.output_text.done", "text": text]) { _, new in new })
                events.append(common.merging(["type": "response.content_part.done", "part": part]) { _, new in new })
            } else {
                // The engine consumes complete function/custom calls in item.done.
                var pending = item
                pending["status"] = "in_progress"
                let custom = item["type"] as? String == "custom_tool_call"
                let field = custom ? "input" : "arguments"
                let eventName = custom ? "custom_tool_call_input" : "function_call_arguments"
                pending[field] = ""
                events.append(["type": "response.output_item.added", "output_index": index, "item": pending])
                let common: [String: Any] = ["item_id": id, "output_index": index, "call_id": item["call_id"]!, "name": item["name"]!]
                events.append(common.merging(["type": "response.\(eventName).delta", "delta": item[field]!]) { _, new in new })
                events.append(common.merging(["type": "response.\(eventName).done", field: item[field]!]) { _, new in new })
            }
            events.append(["type": "response.output_item.done", "output_index": index, "item": item])
        }
        let completed = response(request: request, reply: reply, responseID: responseID, createdAt: createdAt, output: output, completed: true, websiteModelEvidence: websiteModelEvidence, websiteToolSelection: websiteToolSelection)
        events.append(["type": "response.completed", "response": completed])
        var result = Data()
        for (sequence, var event) in events.enumerated() {
            event["sequence_number"] = sequence
            let encoded = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
            result.append(Data("event: \(event["type"] as! String)\ndata: ".utf8))
            result.append(encoded)
            result.append(Data("\n\n".utf8))
        }
        result.append(Data("data: [DONE]\n\n".utf8))
        return result
    }

    static func completedResponse(
        for reply: Reply,
        request: Request,
        responseID: String = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        createdAt: Int = Int(Date().timeIntervalSince1970),
        websiteModelEvidence: WebsiteModelEvidence? = nil,
        websiteToolSelection: String? = nil
    ) throws -> Data {
        _ = try validated(reply, request: request)
        return try JSONSerialization.data(withJSONObject: response(
            request: request, reply: reply, responseID: responseID, createdAt: createdAt,
            output: outputItems(for: reply, responseID: responseID), completed: true, websiteModelEvidence: websiteModelEvidence, websiteToolSelection: websiteToolSelection
        ), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func validated(_ reply: Reply, request: Request) throws -> Reply {
        switch reply {
        case .message, .assistantMessage:
            guard !request.toolPolicy.requiresCall else { throw Failure.rejectedToolChoice }
        case let .toolCalls(calls), let .toolCallsWithCommentary(calls, _):
            guard !calls.isEmpty else { throw Failure.malformedEnvelope }
            guard request.parallelToolCalls || calls.count == 1 else { throw Failure.parallelToolCallsUnsupported }
            if let maximum = request.maximumToolCalls, calls.count > maximum { throw Failure.toolCallLimitExceeded }
            for call in calls {
                let name = call.namespace.map { "\($0).\(call.name)" } ?? call.name
                guard let tool = request.tools[name] else { throw Failure.unknownTool(name) }
                guard request.toolPolicy.allowedNames.contains(name) else { throw Failure.rejectedToolChoice }
                if tool.isCustom {
                    guard call.customInput != nil, call.argumentsJSON.isEmpty else { throw Failure.customInputMustBeString }
                } else {
                    guard call.customInput == nil,
                          (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) is [String: Any] else {
                        throw Failure.argumentsMustBeObject
                    }
                }
            }
        }
        return reply
    }

    private static func booleanParameter(_ name: String, in object: [String: Any], defaultValue: Bool, nullable: Bool = true) throws -> Bool {
        guard let raw = object[name] else { return defaultValue }
        if nullable, raw is NSNull { return defaultValue }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw Failure.invalidParameter(name)
        }
        return number.boolValue
    }

    private static func toolPolicy(_ raw: Any?, tools: [String: OfferedTool]) throws -> ToolPolicy {
        let allNames = Set(tools.keys)
        guard let raw, !(raw is NSNull) else { return .init(allowedNames: allNames, requiresCall: false) }
        if let mode = raw as? String {
            switch mode {
            case "auto": return .init(allowedNames: allNames, requiresCall: false)
            case "none": return .init(allowedNames: [], requiresCall: false)
            case "required":
                guard !allNames.isEmpty else { throw Failure.invalidToolChoice }
                return .init(allowedNames: allNames, requiresCall: true)
            default: throw Failure.invalidToolChoice
            }
        }
        guard let choice = raw as? [String: Any] else { throw Failure.invalidToolChoice }
        func toolName(_ value: [String: Any]) throws -> String {
            guard Set(value.keys) == ["type", "name"], let name = value["name"] as? String,
                  let tool = tools[name], let type = value["type"] as? String,
                  type == (tool.isCustom ? "custom" : "function") else { throw Failure.invalidToolChoice }
            return name
        }
        if choice["type"] as? String == "allowed_tools" {
            guard Set(choice.keys).isSubset(of: ["type", "mode", "tools"]),
                  let values = choice["tools"] as? [[String: Any]], !values.isEmpty, values.count <= 128 else {
                throw Failure.invalidToolChoice
            }
            let names = try values.map(toolName)
            guard Set(names).count == names.count else { throw Failure.invalidToolChoice }
            let mode: String
            if let rawMode = choice["mode"] {
                guard let value = rawMode as? String else { throw Failure.invalidToolChoice }
                mode = value
            } else { mode = "auto" }
            guard ["auto", "required", "none"].contains(mode) else { throw Failure.invalidToolChoice }
            return .init(allowedNames: mode == "none" ? [] : Set(names), requiresCall: mode == "required")
        }
        return .init(allowedNames: [try toolName(choice)], requiresCall: true)
    }

    /// Website adapters have no sampler or provider-side storage controls. The
    /// numeric defaults below describe this adapter's normalized contract;
    /// they are not measurements of the website's inaccessible sampler.
    private static func responseConfiguration(_ object: [String: Any], schemas: [[String: Any]], parallel: Bool) throws -> Data {
        if try booleanParameter("store", in: object, defaultValue: false, nullable: false) { throw Failure.unsupportedParameter("store") }
        if try booleanParameter("background", in: object, defaultValue: false, nullable: false) { throw Failure.unsupportedParameter("background") }
        let defaults: [String: Double] = ["temperature": 1, "top_p": 1, "presence_penalty": 0, "frequency_penalty": 0, "top_logprobs": 0]
        for (name, expected) in defaults {
            guard let raw = object[name], !(raw is NSNull) else { continue }
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
                throw Failure.invalidParameter(name)
            }
            if value.doubleValue != expected { throw Failure.unsupportedParameter(name) }
        }
        if let truncation = object["truncation"] {
            guard let value = truncation as? String, ["auto", "disabled"].contains(value) else { throw Failure.invalidParameter("truncation") }
        }
        if let tier = object["service_tier"] {
            guard let value = tier as? String, ["auto", "default"].contains(value) else { throw Failure.unsupportedParameter("service_tier") }
        }
        var text: [String: Any] = ["format": ["type": "text"]]
        if let raw = object["text"], !(raw is NSNull) {
            guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: ["format", "verbosity"]) else { throw Failure.invalidParameter("text") }
            if let format = value["format"], !(format is NSNull) {
                guard let spec = format as? [String: Any], Set(spec.keys) == ["type"], spec["type"] as? String == "text" else {
                    throw Failure.unsupportedParameter("text.format")
                }
            }
            if let rawVerbosity = value["verbosity"] {
                guard let verbosity = rawVerbosity as? String, ["low", "medium", "high"].contains(verbosity) else { throw Failure.invalidParameter("text.verbosity") }
                text["verbosity"] = verbosity
            }
        }
        for name in ["max_output_tokens", "max_tool_calls"] {
            if let raw = object[name], !(raw is NSNull) {
                guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                      n.doubleValue.rounded(.towardZero) == n.doubleValue,
                      n.doubleValue >= (name == "max_output_tokens" ? 16 : 1),
                      n.doubleValue <= Double(Int32.max) else { throw Failure.invalidParameter(name) }
            }
        }
        if let raw = object["reasoning"], !(raw is NSNull) {
            guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: ["effort", "summary"]) else { throw Failure.invalidParameter("reasoning") }
            for (name, allowed) in ["effort": ["none", "minimal", "low", "medium", "high", "xhigh"], "summary": ["concise", "detailed", "auto"]] {
                if let rawValue = value[name], !(rawValue is NSNull) {
                    guard let text = rawValue as? String, allowed.contains(text) else { throw Failure.invalidParameter("reasoning.\(name)") }
                }
            }
        }
        var metadata: [String: String] = [:]
        if let raw = object["metadata"], !(raw is NSNull) {
            guard let value = raw as? [String: String], value.count <= 16,
                  value.allSatisfy({ $0.key.count <= 64 && $0.value.count <= 512 }) else { throw Failure.invalidParameter("metadata") }
            metadata = value
        }
        for name in ["safety_identifier", "prompt_cache_key"] {
            if let raw = object[name], !(raw is NSNull) {
                guard let value = raw as? String, value.count <= 64 else { throw Failure.invalidParameter(name) }
            }
        }
        if let raw = object["stream_options"], !(raw is NSNull) {
            guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: ["include_obfuscation"]) else { throw Failure.invalidParameter("stream_options") }
            if try booleanParameter("include_obfuscation", in: value, defaultValue: false, nullable: false) {
                throw Failure.unsupportedParameter("stream_options.include_obfuscation")
            }
        }
        if let raw = object["include"], !(raw is NSNull) {
            guard let values = raw as? [String] else { throw Failure.invalidParameter("include") }
            // The pinned Codex engine sends this optional include on every
            // request. No reasoning items or encrypted payload are invented;
            // absence of such items remains a valid response to this hint.
            guard values.allSatisfy({ $0 == "reasoning.encrypted_content" }) else { throw Failure.unsupportedParameter("include") }
        }
        func normalizedTool(_ tool: [String: Any]) -> [String: Any] {
            var value = tool
            if value["type"] as? String == "function" {
                value["description"] = value["description"] ?? NSNull()
                value["strict"] = value["strict"] ?? NSNull()
            } else if value["type"] as? String == "namespace", let children = value["tools"] as? [[String: Any]] {
                value["tools"] = children.map(normalizedTool)
            }
            return value
        }
        var choice: Any = object["tool_choice"] ?? "auto"
        if choice is NSNull { choice = "auto" }
        if var allowed = choice as? [String: Any], allowed["type"] as? String == "allowed_tools", allowed["mode"] == nil {
            allowed["mode"] = "auto"; choice = allowed
        }
        let result: [String: Any] = [
            "previous_response_id": NSNull(), "instructions": object["instructions"] ?? NSNull(),
            "tools": schemas.map(normalizedTool), "tool_choice": choice, "truncation": "disabled",
            "parallel_tool_calls": parallel, "text": text, "temperature": 1, "top_p": 1,
            "presence_penalty": 0, "frequency_penalty": 0, "top_logprobs": 0, "reasoning": NSNull(),
            "max_output_tokens": NSNull(), "max_tool_calls": object["max_tool_calls"] ?? NSNull(), "store": false,
            "background": false, "service_tier": "default", "metadata": metadata,
            "safety_identifier": NSNull(), "prompt_cache_key": NSNull(),
        ]
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func insertTool(_ schema: [String: Any], namespace: String?, into tools: inout [String: OfferedTool]) throws {
        guard let type = schema["type"] as? String, type == "function" || type == "custom" else { throw Failure.unsupportedToolType }
        guard let name = schema["name"] as? String, !name.isEmpty else { throw Failure.invalidTools }
        if type == "function", !(schema["parameters"] is [String: Any]) { throw Failure.invalidTools }
        if let description = schema["description"], !(description is NSNull), !(description is String) { throw Failure.invalidTools }
        if type == "function", let strict = schema["strict"], !(strict is NSNull) {
            guard let value = strict as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw Failure.invalidTools }
            // Object shape and offered identity are validated here; the host
            // executor validates its own native argument contract. Arbitrary
            // client JSON Schema enforcement is not yet implemented.
            if value.boolValue { throw Failure.unsupportedParameter("tools.strict") }
        }
        if type == "custom", let format = schema["format"], !(format is [String: Any]) { throw Failure.invalidTools }
        let offeredName = namespace.map { "\($0).\(name)" } ?? name
        guard tools[offeredName] == nil else { throw Failure.invalidTools }
        tools[offeredName] = OfferedTool(name: name, namespace: namespace, isCustom: type == "custom")
    }

    private static func rejectUnsupportedModalities(in input: Any?) throws {
        guard let items = input as? [Any] else { return }
        for value in items {
            guard let item = value as? [String: Any] else { continue }
            switch item["type"] as? String {
            case "item_reference": throw Failure.unsupportedParameter("input.item_reference")
            case "message":
                try rejectUnsupportedContentParts(item["content"])
            case nil where item["role"] is String:
                // Responses also accepts messages without an explicit type.
                try rejectUnsupportedContentParts(item["content"])
            case "function_call_output", "custom_tool_call_output":
                // Codex serializes structured tool observations as an output
                // content array. A string output is ordinary quoted tool data.
                try rejectUnsupportedContentParts(item["output"])
            default:
                break
            }
        }
    }

    private static func rejectUnsupportedContentParts(_ content: Any?) throws {
        guard let parts = content as? [Any] else { return }
        for value in parts {
            guard let part = value as? [String: Any] else { continue }
            switch part["type"] as? String {
            case "input_image": throw Failure.unsupportedModality(.image)
            case "input_audio": throw Failure.unsupportedModality(.audio)
            case "input_file": throw Failure.unsupportedModality(.file)
            case "input_video": throw Failure.unsupportedModality(.video)
            default: break
            }
        }
        // Do not recursively inspect arbitrary objects or parse text as JSON:
        // page text, tool arguments, and examples can legitimately mention
        // input_image/input_audio without being attachments.
    }

    private static func removingJSONFence(_ text: String) -> String {
        guard text.count >= 6, text.hasPrefix("```"), text.hasSuffix("```") else { return text }
        let end = text.index(text.endIndex, offsetBy: -3)
        if let newline = text.firstIndex(of: "\n") {
            let label = text[text.index(text.startIndex, offsetBy: 3)..<newline]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty || label.lowercased() == "json" {
                return text[text.index(after: newline)..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // A website can render a whole JSON wrapper inline. Remove only its
        // exact outer delimiters; the complete body still must parse as JSON.
        // Never search for an object inside prose or repair damaged JSON.
        let content = text[text.index(text.startIndex, offsetBy: 3)..<end]
        guard let boundary = content.firstIndex(where: \.isWhitespace),
              content[..<boundary].lowercased() == "json" else { return text }
        return content[boundary...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeToolEnvelope(_ text: String) -> Bool {
        guard text.hasPrefix("{") else { return false }
        return text.range(of: #"["']type["']\s*:\s*["']tool_calls["']"#, options: .regularExpression) != nil
    }

    private static func outputItems(for reply: Reply, responseID: String) -> [[String: Any]] {
        let identity = responseID.hasPrefix("resp_") ? String(responseID.dropFirst(5)) : responseID
        switch reply {
        case let .message(text):
            return [["id": "msg_\(identity)", "type": "message", "role": "assistant", "status": "completed", "phase": "final_answer",
                     "content": [["type": "output_text", "text": text, "annotations": [] as [String]]]]]
        case let .assistantMessage(text, phase):
            return [["id": "msg_\(identity)", "type": "message", "role": "assistant", "status": "completed", "phase": phase.rawValue,
                     "content": [["type": "output_text", "text": text, "annotations": [] as [String]]]]]
        case let .toolCallsWithCommentary(calls, commentary):
            return outputItems(for: .assistantMessage(commentary, phase: .commentary), responseID: responseID)
                + outputItems(for: .toolCalls(calls), responseID: responseID)
        case let .toolCalls(calls):
            return calls.enumerated().map { index, call in
                var item: [String: Any] = ["id": "fc_\(identity)_\(index)", "type": "function_call", "status": "completed",
                                          "call_id": "call_\(identity)_\(index)", "name": call.name, "arguments": call.argumentsJSON]
                if let input = call.customInput {
                    item["type"] = "custom_tool_call"
                    item["id"] = "ctc_\(identity)_\(index)"
                    item.removeValue(forKey: "arguments")
                    item["input"] = input
                }
                if let namespace = call.namespace { item["namespace"] = namespace }
                return item
            }
        }
    }

    private static func response(request: Request, reply: Reply, responseID: String, createdAt: Int, output: [[String: Any]], completed: Bool, websiteModelEvidence: WebsiteModelEvidence? = nil, websiteToolSelection: String? = nil) -> [String: Any] {
        let finalText: String
        let endTurn: Bool
        switch reply {
        case let .message(text): finalText = completed ? text : ""; endTurn = true
        case let .assistantMessage(text, phase): finalText = completed ? text : ""; endTurn = phase == .finalAnswer
        case let .toolCallsWithCommentary(_, commentary): finalText = completed ? commentary : ""; endTurn = false
        case .toolCalls: finalText = ""; endTurn = false
        }
        // Configuration was validated before the browser was contacted.
        var value = (try? JSONSerialization.jsonObject(with: request.responseConfiguration)) as? [String: Any] ?? [:]
        value.merge(["id": responseID, "object": "response", "created_at": createdAt, "model": request.model,
                "completed_at": completed ? createdAt : NSNull(),
                "status": completed ? "completed" : "in_progress", "output": output, "output_text": finalText,
                "error": NSNull(), "incomplete_details": NSNull(), "usage": NSNull(),
                "end_turn": completed ? endTurn : false]) { _, new in new }
        // This reserved key describes host selection, never execution. A client
        // metadata value cannot impersonate the host's finite diagnostic.
        var metadata = value["metadata"] as? [String: Any] ?? [:]
        var metadataChanged = metadata.removeValue(forKey: "computa_website_tool_selection") != nil
        if let websiteModelEvidence {
            metadata["computa_website_model"] = websiteModelEvidence.dictionary
            metadataChanged = true
        }
        if let websiteToolSelection {
            metadata["computa_website_tool_selection"] = websiteToolSelection
            metadataChanged = true
        }
        if metadataChanged { value["metadata"] = metadata }
        return value
    }
}

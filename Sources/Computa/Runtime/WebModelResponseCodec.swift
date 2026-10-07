import Foundation

/// The browser is a stateless model transport. It never owns a tool or executes
/// an action: validated function calls return to the existing App Server loop.
enum WebModelResponseCodec {
    static let maximumPromptBytes = 160 * 1_024

    struct Request: Sendable {
        let model: String
        let prompt: String
        let runtimeInstructions: String
        let currentUserInstructions: String
        let offeredToolNames: Set<String>
        let customToolNames: Set<String>
        fileprivate let tools: [String: OfferedTool]
    }

    fileprivate struct OfferedTool: Sendable {
        let name: String
        let namespace: String?
        let isCustom: Bool
    }

    struct ToolCall: Equatable, Sendable {
        let name: String
        let argumentsJSON: String
        let namespace: String?
        var customInput: String? = nil
    }

    enum Reply: Equatable, Sendable {
        case message(String)
        case toolCalls([ToolCall])
    }

    enum Modality: String, Equatable, Sendable {
        case image
        case audio
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
            case let .promptTooLarge(actual, maximum):
                "The complete web model prompt is \(actual) bytes, exceeding the \(maximum)-byte limit. No context was truncated or submitted."
            case .emptyReply: "The website returned an empty model reply."
            case .malformedEnvelope: "The website returned a malformed model response envelope. No tool calls from this reply were dispatched."
            case let .unknownTool(name): "The website requested an unoffered tool: \(name). No tool calls from this reply were dispatched."
            case .argumentsMustBeObject: "Web model tool arguments must be a JSON object. No tool calls from this reply were dispatched."
            case .customInputMustBeString: "A custom tool needs literal string input and no function arguments. No tool calls from this reply were dispatched."
            }
        }
    }

    static func prepareRequest(_ data: Data) throws -> Request {
        // Reject before expanding a large JSON body into prompt storage.
        guard data.count <= maximumPromptBytes else {
            throw Failure.promptTooLarge(actualBytes: data.count, maximumBytes: maximumPromptBytes)
        }
        guard let originalJSON = String(data: data, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidRequest
        }
        guard let model = object["model"] as? String,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.missingModel
        }
        guard object["input"] is String || object["input"] is [Any] else {
            throw Failure.missingInput
        }
        try rejectUnsupportedModalities(in: object["input"])
        if let previous = object["previous_response_id"], !(previous is NSNull) {
            throw Failure.previousResponseUnsupported
        }
        if let instructions = object["instructions"], !(instructions is String), !(instructions is NSNull) {
            throw Failure.invalidRequest
        }
        let schemas: [[String: Any]]
        if let raw = object["tools"], !(raw is NSNull) {
            guard let values = raw as? [[String: Any]] else { throw Failure.invalidTools }
            schemas = values
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
        let customNames = Set(offered.filter { $0.value.isCustom }.keys)
        let runtimeInstructions = ComputaAgentInstructions.webInferenceContract(offeredFunctions: offered.mapValues(\.name), customToolNames: customNames)
        let latestUserItemIndex = (object["input"] as? [Any])?.lastIndex { item in
            guard let message = item as? [String: Any], message["role"] as? String == "user" else { return false }
            return message["type"] == nil || message["type"] as? String == "message"
        }
        let currentUserInstructions = ComputaAgentInstructions.webCurrentUserContract(
            latestUserItemIndex: latestUserItemIndex, inputIsString: object["input"] is String)
        let prompt = """
        \(runtimeInstructions)

        The JSON request below is the complete conversation and available tool schemas. Follow its instructions and input roles in order; input can include prior assistant calls and their tool outputs. Continue from the newest input. Do not claim an action happened before its matching local tool output confirms it.
        COMPLETE_RESPONSES_REQUEST_JSON:
        \(originalJSON)
        END_COMPLETE_RESPONSES_REQUEST_JSON.

        \(currentUserInstructions)

        \(ComputaAgentInstructions.webResponseContract(offeredToolNames: Array(offered.keys), customToolNames: customNames))
        """
        let bytes = prompt.utf8.count
        guard bytes <= maximumPromptBytes else {
            throw Failure.promptTooLarge(actualBytes: bytes, maximumBytes: maximumPromptBytes)
        }
        return Request(model: model, prompt: prompt, runtimeInstructions: runtimeInstructions,
                       currentUserInstructions: currentUserInstructions,
                       offeredToolNames: Set(offered.keys), customToolNames: customNames, tools: offered)
    }

    /// Embedded inference requires its response contract. Generic callers keep
    /// ordinary-text compatibility; strict callers never repair or extract JSON.
    static func parseReply(_ text: String, request: Request, requireEnvelope: Bool = false) throws -> Reply {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyReply }
        let candidate = removingJSONFence(trimmed)
        guard let data = candidate.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A damaged tool envelope must never be presented as a successful
            // final answer. Ordinary prose/code/JSON still remains ordinary text.
            if requireEnvelope || looksLikeToolEnvelope(candidate) { throw Failure.malformedEnvelope }
            return .message(text)
        }
        switch envelope["type"] as? String {
        case "message":
            guard let message = envelope["text"] as? String else { throw Failure.malformedEnvelope }
            return .message(message)
        case "tool_calls":
            guard let calls = envelope["calls"] as? [[String: Any]], !calls.isEmpty else {
                throw Failure.malformedEnvelope
            }
            let validated = try calls.map { call -> ToolCall in
                guard let offeredName = call["name"] as? String, !offeredName.isEmpty else {
                    throw Failure.malformedEnvelope
                }
                guard let tool = request.tools[offeredName] else { throw Failure.unknownTool(offeredName) }
                if tool.isCustom {
                    guard Set(call.keys) == ["name", "input"], let input = call["input"] as? String else {
                        throw Failure.customInputMustBeString
                    }
                    return ToolCall(name: tool.name, argumentsJSON: "", namespace: tool.namespace, customInput: input)
                }
                guard call["input"] == nil, let arguments = call["arguments"] as? [String: Any] else {
                    throw Failure.argumentsMustBeObject
                }
                let encoded = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes])
                return ToolCall(name: tool.name, argumentsJSON: String(decoding: encoded, as: UTF8.self), namespace: tool.namespace)
            }
            return .toolCalls(validated)
        default:
            if requireEnvelope { throw Failure.malformedEnvelope }
            return .message(text)
        }
    }

    /// All items are buffered from the website before this stream is emitted.
    /// Browser providers do not expose verified token counts, so usage is null.
    static func streamData(
        for reply: Reply,
        request: Request,
        responseID: String = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        createdAt: Int = Int(Date().timeIntervalSince1970)
    ) throws -> Data {
        let output = outputItems(for: reply, responseID: responseID)
        let initial = response(request: request, reply: reply, responseID: responseID, createdAt: createdAt, output: [], completed: false)
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
        let completed = response(request: request, reply: reply, responseID: responseID, createdAt: createdAt, output: output, completed: true)
        events.append(["type": "response.completed", "response": completed])
        var result = Data()
        for (sequence, var event) in events.enumerated() {
            event["sequence_number"] = sequence
            let encoded = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
            result.append(Data("event: \(event["type"] as! String)\ndata: ".utf8))
            result.append(encoded)
            result.append(Data("\n\n".utf8))
        }
        return result
    }

    static func completedResponse(
        for reply: Reply,
        request: Request,
        responseID: String = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        createdAt: Int = Int(Date().timeIntervalSince1970)
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: response(
            request: request, reply: reply, responseID: responseID, createdAt: createdAt,
            output: outputItems(for: reply, responseID: responseID), completed: true
        ), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func insertTool(_ schema: [String: Any], namespace: String?, into tools: inout [String: OfferedTool]) throws {
        guard let type = schema["type"] as? String, type == "function" || type == "custom" else { throw Failure.unsupportedToolType }
        guard let name = schema["name"] as? String, !name.isEmpty else { throw Failure.invalidTools }
        if type == "function", !(schema["parameters"] is [String: Any]) { throw Failure.invalidTools }
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
            default: break
            }
        }
        // Do not recursively inspect arbitrary objects or parse text as JSON:
        // page text, tool arguments, and examples can legitimately mention
        // input_image/input_audio without being attachments.
    }

    private static func removingJSONFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"),
              let newline = text.firstIndex(of: "\n") else { return text }
        let label = text[text.index(text.startIndex, offsetBy: 3)..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.isEmpty || label.lowercased() == "json" else { return text }
        let content = text[text.index(after: newline)..<text.index(text.endIndex, offsetBy: -3)]
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeToolEnvelope(_ text: String) -> Bool {
        guard text.hasPrefix("{") else { return false }
        return text.range(of: #"["']type["']\s*:\s*["']tool_calls["']"#, options: .regularExpression) != nil
    }

    private static func outputItems(for reply: Reply, responseID: String) -> [[String: Any]] {
        let identity = responseID.hasPrefix("resp_") ? String(responseID.dropFirst(5)) : responseID
        switch reply {
        case let .message(text):
            return [["id": "msg_\(identity)", "type": "message", "role": "assistant", "status": "completed",
                     "content": [["type": "output_text", "text": text, "annotations": [] as [String]]]]]
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

    private static func response(request: Request, reply: Reply, responseID: String, createdAt: Int, output: [[String: Any]], completed: Bool) -> [String: Any] {
        let finalText: String
        let endTurn: Bool
        switch reply {
        case let .message(text): finalText = completed ? text : ""; endTurn = true
        case .toolCalls: finalText = ""; endTurn = false
        }
        return ["id": responseID, "object": "response", "created_at": createdAt, "model": request.model,
                "status": completed ? "completed" : "in_progress", "output": output, "output_text": finalText,
                "error": NSNull(), "incomplete_details": NSNull(), "usage": NSNull(), "store": false,
                "end_turn": completed ? endTurn : false]
    }
}

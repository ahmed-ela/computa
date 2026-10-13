import Foundation
import CoreFoundation
import CryptoKit
import Security

/// Stateless protocol translation. Tool execution remains entirely in the native engine.
/// A reply is completely validated before an output_item.done can authorize a tool.
enum APIModelResponseCodec {
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
    }
    private static let maximumText = 2_000_000

    static func prepare(_ data: Data, selection: APIProviderCatalog.Selection, threadID: String,
                        capsules: APIReasoningCapsules) throws -> Request {
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
        let historyTools = try parseTools(raw["tools"])
        if let definitions = raw["tools"] as? [[String: Any]] {
            raw["tools"] = ComputaModelToolCatalog.visibleToolDefinitions(definitions, modelID: localID)
        }
        // Removing an active tool must not renumber its neighbours: historical
        // calls and current declarations share one stable provider identity.
        let historyByIdentity = Dictionary(uniqueKeysWithValues: historyTools.map { ($0.identity, $0) })
        let tools = try parseTools(raw["tools"]).map { visible -> Tool in
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
        let history = try messages(raw, tools: historyTools, selection: selection, threadID: threadID, capsules: capsules)
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
                       stream: stream, body: try json(body), tools: tools, allowedTools: allowed, requiredTool: required,
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

    private static func parseTools(_ value: Any?) throws -> [Tool] {
        if absent(value) { return [] }
        guard let definitions = value as? [[String: Any]], definitions.count <= 256 else { throw Failure.invalidTool }
        var result: [Tool] = [], identities = Set<String>()
        func add(_ definition: [String: Any], namespace: String?) throws {
            guard let type = definition["type"] as? String, ["function", "custom"].contains(type),
                  let name = definition["name"] as? String, validName(name), result.count < 256 else { throw Failure.invalidTool }
            if !absent(definition["description"]), !(definition["description"] is String) { throw Failure.invalidTool }
            if !absent(definition["strict"]), strictBool(definition["strict"]) == nil { throw Failure.invalidTool }
            let custom = type == "custom"
            let schema: [String: Any]
            if custom {
                schema = ["type": "object", "properties": ["input": ["type": "string"]], "required": ["input"], "additionalProperties": false]
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
            let tool = Tool(name: name, namespace: namespace, wireName: "computa_tool_\(result.count)", custom: custom,
                            schema: schema, description: description)
            guard identities.insert(tool.identity).inserted, tool.description.utf8.count <= 64_000 else { throw Failure.invalidTool }
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
                                 threadID: String, capsules: APIReasoningCapsules) throws -> History {
        var messages: [[String: Any]] = [], seen = Set<String>(), pending = Set<String>(), pendingCustom = Set<String>()
        var reasoning: APIReasoningCapsules.Payload?, assistant: [String: Any]?, calls: [[String: Any]] = []
        func flush() throws {
            guard var message = assistant else {
                guard reasoning == nil else { throw Failure.invalidHistory }; return
            }
            if !calls.isEmpty { message["tool_calls"] = calls }
            if let value = reasoning {
                guard Set(value.callIDs) == Set(calls.compactMap { $0["id"] as? String }) else { throw Failure.invalidReasoning }
                guard let text = value.reasoning, value.remoteEncryptedContent == nil else { throw Failure.invalidReasoning }
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
                      let name = item["name"] as? String,
                      let tool = tools.first(where: { $0.name == name && $0.namespace == item["namespace"] as? String }),
                      tool.custom == (type == "custom_tool_call") else { throw Failure.invalidHistory }
                let arguments: String
                if tool.custom {
                    guard let input = item["input"] as? String else { throw Failure.invalidHistory }
                    arguments = String(decoding: try json(["input": input]), as: UTF8.self); pendingCustom.insert(id)
                } else {
                    guard let value = item["arguments"] as? String else { throw Failure.invalidHistory }
                    arguments = value
                }
                _ = try validatedArguments(arguments, tool: tool)
                if assistant == nil { assistant = ["role": "assistant", "content": NSNull()] }
                calls.append(["id": id, "type": "function", "function": ["name": tool.wireName, "arguments": arguments]])
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
        if request.provider.wireAPI == .responses { return try decodeResponses(result.body, request: request) }
        let envelope: [String: Any], textDeltas: [String], argumentDeltas: [[String]]
        if result.contentType.contains("text/event-stream") {
            let assembled = try assembleChatStream(result.body)
            envelope = assembled.object; textDeltas = assembled.text; argumentDeltas = assembled.arguments
        } else {
            guard let object = try JSONSerialization.jsonObject(with: result.body) as? [String: Any] else { throw Failure.invalidResponse }
            envelope = object; textDeltas = []; argumentDeltas = []
        }
        guard envelope["model"] as? String == request.model.id else { throw Failure.modelMismatch }
        guard let choices = envelope["choices"] as? [[String: Any]], choices.count == 1,
              try integer(choices[0]["index"], default: 0, range: 0...0) == 0,
              let message = choices[0]["message"] as? [String: Any], message["role"] as? String == "assistant",
              let finish = choices[0]["finish_reason"] as? String else { throw Failure.invalidResponse }
        guard ["stop", "tool_calls"].contains(finish) else { throw Failure.incompleteResponse }
        let text: String
        if absent(message["content"]) { text = "" }
        else if let value = message["content"] as? String { text = value }
        else { throw Failure.invalidResponse }
        guard absent(message["refusal"]), absent(message["function_call"]) else { throw Failure.invalidResponse }
        let calls: [[String: Any]]
        if absent(message["tool_calls"]) { calls = [] }
        else if let value = message["tool_calls"] as? [[String: Any]] { calls = value }
        else { throw Failure.invalidResponse }
        guard calls.count <= request.maximumCalls, !request.requiredTool || !calls.isEmpty,
              (finish == "tool_calls") == !calls.isEmpty else { throw Failure.invalidResponse }
        let responseID = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var output: [[String: Any]] = [], callIDs = request.historyCallIDs, actualIDs: [String] = []
        for call in calls {
            guard call["type"] as? String == "function", let id = call["id"] as? String, validCallID(id), callIDs.insert(id).inserted,
                  let function = call["function"] as? [String: Any], let wireName = function["name"] as? String,
                  request.allowedTools.contains(wireName), let tool = request.tools.first(where: { $0.wireName == wireName }),
                  let arguments = function["arguments"] as? String else { throw Failure.invalidTool }
            let parsed = try validatedArguments(arguments, tool: tool)
            var item: [String: Any] = ["id": (tool.custom ? "ctc_" : "fc_") + UUID().uuidString, "type": tool.custom ? "custom_tool_call" : "function_call", "status": "completed", "call_id": id, "name": tool.name]
            if let namespace = tool.namespace { item["namespace"] = namespace }
            if tool.custom { item["input"] = parsed["input"] as! String } else { item["arguments"] = arguments }
            output.append(item); actualIDs.append(id)
        }
        if !text.isEmpty {
            output.insert(["id": "msg_" + UUID().uuidString, "type": "message", "status": "completed", "role": "assistant",
                           "phase": calls.isEmpty ? "final_answer" : "commentary", "content": [["type": "output_text", "text": text, "annotations": []]]], at: 0)
        }
        if let reasoning = message["reasoning"] as? String, !reasoning.isEmpty {
            let id = "rs_" + responseID
            let capsule = try request.capsules.seal(.init(reasoning: reasoning, callIDs: actualIDs, responseID: responseID), itemID: id,
                                                   providerID: request.provider.id, modelID: request.model.id, baseURL: request.provider.baseURL, threadID: request.threadID)
            output.insert(["id": id, "type": "reasoning", "status": "completed", "summary": [], "encrypted_content": capsule], at: 0)
        } else if !absent(message["reasoning"]) && !(message["reasoning"] is String) { throw Failure.invalidResponse }
        guard !output.isEmpty else { throw Failure.invalidResponse }
        let usage = try usage(envelope["usage"], responses: false)
        return Reply(response: response(id: responseID, request: request, output: output, text: text, usage: usage),
                     textDeltas: textDeltas.isEmpty && !text.isEmpty ? [text] : textDeltas, argumentDeltas: argumentDeltas)
    }

    private static func decodeResponses(_ data: Data, request: Request) throws -> Reply {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], raw["object"] as? String == "response",
              raw["status"] as? String == "completed", absent(raw["error"]), absent(raw["incomplete_details"]),
              let original = raw["output"] as? [[String: Any]], !original.isEmpty else { throw Failure.incompleteResponse }
        guard raw["model"] as? String == request.model.id else { throw Failure.modelMismatch }
        var output: [[String: Any]] = [], text = "", ids = request.historyCallIDs, itemIDs = Set<String>(), count = 0
        let responseID = raw["id"] as? String ?? "resp_" + UUID().uuidString
        for value in original {
            guard let type = value["type"] as? String, let id = value["id"] as? String, !id.isEmpty, itemIDs.insert(id).inserted else { throw Failure.invalidResponse }
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
                      let parts = value["content"] as? [[String: Any]], parts.allSatisfy({ $0["type"] as? String == "output_text" && $0["text"] is String }) else { throw Failure.invalidResponse }
                let messageText = parts.compactMap { $0["text"] as? String }.joined(); text += messageText
                output.append(["id": id, "type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": messageText, "annotations": []]]])
            case "reasoning":
                guard let summary = value["summary"] as? [[String: Any]], summary.allSatisfy({ $0["type"] as? String == "summary_text" && $0["text"] is String }) else { throw Failure.invalidResponse }
                var item: [String: Any] = ["id": id, "type": type, "status": "completed", "summary": summary]
                if let encrypted = value["encrypted_content"] as? String {
                    let payload = APIReasoningCapsules.Payload(reasoning: nil, callIDs: [], responseID: responseID, remoteEncryptedContent: encrypted, remoteItemID: id)
                    item["encrypted_content"] = try request.capsules.seal(payload, itemID: id, providerID: request.provider.id,
                                                                         modelID: request.model.id, baseURL: request.provider.baseURL, threadID: request.threadID)
                } else if !absent(value["encrypted_content"]) { throw Failure.invalidResponse }
                output.append(item)
            default: throw Failure.invalidResponse
            }
        }
        guard count <= request.maximumCalls, !request.requiredTool || count > 0 else { throw Failure.invalidTool }
        return Reply(response: response(id: "resp_" + UUID().uuidString, request: request, output: output, text: text,
                                        usage: try usage(raw["usage"], responses: true)), textDeltas: text.isEmpty ? [] : [text], argumentDeltas: [])
    }

    private struct ChatStream { let object: [String: Any]; let text: [String]; let arguments: [[String]] }
    private static func assembleChatStream(_ data: Data) throws -> ChatStream {
        guard let string = String(data: data, encoding: .utf8) else { throw Failure.invalidResponse }
        var done = false, model: String?, id: String?, role: String?, finish: String?, usage: Any?
        var text: [String] = [], reasoning = "", calls: [Int: (id: String, name: String, arguments: [String])] = [:]
        for event in string.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            let payload = event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            if payload.isEmpty { continue }
            guard !done else { throw Failure.invalidResponse }
            if payload == "[DONE]" { done = true; continue }
            guard let chunkData = payload.data(using: .utf8), let chunk = try JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                  chunk["error"] == nil, let chunkModel = chunk["model"] as? String, let chunkID = chunk["id"] as? String,
                  let choices = chunk["choices"] as? [[String: Any]], choices.count <= 1 else { throw Failure.invalidResponse }
            if let model { guard model == chunkModel, id == chunkID else { throw Failure.invalidResponse } }
            else { model = chunkModel; id = chunkID }
            if !absent(chunk["usage"]) { usage = chunk["usage"] }
            guard let choice = choices.first else { continue }
            guard try integer(choice["index"], default: -1, range: 0...0) == 0, finish == nil,
                  let delta = choice["delta"] as? [String: Any] else { throw Failure.invalidResponse }
            if let value = delta["role"] as? String { guard value == "assistant", role == nil || role == value else { throw Failure.invalidResponse }; role = value }
            if let value = delta["content"] as? String { text.append(value) } else if !absent(delta["content"]) { throw Failure.invalidResponse }
            if let value = delta["reasoning"] as? String { reasoning += value } else if !absent(delta["reasoning"]) { throw Failure.invalidResponse }
            if let rows = delta["tool_calls"] as? [[String: Any]] {
                for row in rows {
                    let index = try integer(row["index"], default: -1, range: 0...127)
                    var call = calls[index] ?? (id: "", name: "", arguments: [])
                    if let value = row["id"] as? String { guard call.id.isEmpty else { throw Failure.invalidResponse }; call.id = value }
                    if let type = row["type"] as? String { guard type == "function" else { throw Failure.invalidTool } }
                    if let function = row["function"] as? [String: Any] {
                        if let value = function["name"] as? String { call.name += value }
                        if let value = function["arguments"] as? String { call.arguments.append(value) }
                    }
                    calls[index] = call
                }
            } else if !absent(delta["tool_calls"]) { throw Failure.invalidResponse }
            if let value = choice["finish_reason"] as? String { finish = value }
        }
        guard done, let model, let id, let finish, role == "assistant", calls.keys.sorted() == Array(0..<calls.count) else { throw Failure.incompleteResponse }
        let rows = (0..<calls.count).map { index -> [String: Any] in
            let call = calls[index]!
            return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments.joined()]]
        }
        let message: [String: Any] = ["role": "assistant", "content": text.joined(), "reasoning": reasoning, "tool_calls": rows]
        return ChatStream(object: ["id": id, "model": model, "choices": [["index": 0, "message": message, "finish_reason": finish]], "usage": usage ?? NSNull()],
                          text: text, arguments: (0..<calls.count).map { calls[$0]!.arguments })
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

    private static func response(id: String, request: Request, output: [[String: Any]], text: String, usage: Any) -> [String: Any] {
        var result = request.responseConfiguration
        result.merge(["id": id, "object": "response", "created_at": Int(Date().timeIntervalSince1970), "completed_at": Int(Date().timeIntervalSince1970), "status": "completed", "model": request.localModelID, "output": output, "output_text": text, "error": NSNull(), "incomplete_details": NSNull(), "usage": usage, "end_turn": !output.contains { ["function_call", "custom_tool_call"].contains($0["type"] as? String ?? "") }]) { _, value in value }
        return result
    }
    private static func usage(_ value: Any?, responses: Bool) throws -> Any {
        if absent(value) { return NSNull() }
        guard let usage = value as? [String: Any] else { throw Failure.invalidResponse }
        let input = try integer(usage[responses ? "input_tokens" : "prompt_tokens"], default: -1, range: 0...100_000_000)
        let output = try integer(usage[responses ? "output_tokens" : "completion_tokens"], default: -1, range: 0...100_000_000)
        let total = try integer(usage["total_tokens"], default: input + output, range: 0...200_000_000)
        guard total == input + output else { throw Failure.invalidResponse }
        let outputDetailValue = usage[responses ? "output_tokens_details" : "completion_tokens_details"]
        guard absent(outputDetailValue) || outputDetailValue is [String: Any] else { throw Failure.invalidResponse }
        let details = outputDetailValue as? [String: Any]
        let reasoning = try integer(details?["reasoning_tokens"], default: 0, range: 0...output)
        let inputDetailValue = usage[responses ? "input_tokens_details" : "prompt_tokens_details"]
        guard absent(inputDetailValue) || inputDetailValue is [String: Any] else { throw Failure.invalidResponse }
        let inputDetails = inputDetailValue as? [String: Any]
        let cached = try integer(inputDetails?["cached_tokens"], default: 0, range: 0...input)
        return ["input_tokens": input, "output_tokens": output, "total_tokens": total, "input_tokens_details": ["cached_tokens": cached], "output_tokens_details": ["reasoning_tokens": reasoning]]
    }
    private static func validatedArguments(_ text: String, tool: Tool) throws -> [String: Any] {
        guard text.utf8.count <= maximumText, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              matches(object, schema: tool.schema, root: tool.schema, depth: 0) else { throw Failure.invalidArguments }
        return object
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
    func seal(_ payload: Payload, itemID: String, providerID: String, modelID: String, baseURL: URL, threadID: String) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard data.count <= 2_000_000 else { throw APIModelResponseCodec.Failure.invalidReasoning }
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

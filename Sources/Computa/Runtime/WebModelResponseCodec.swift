import Foundation
import CoreFoundation

/// The browser is a model transport. It never owns a tool or executes
/// an action: validated function calls return to the existing App Server loop.
enum WebModelResponseCodec {
    static let maximumPromptBytes = 160 * 1_024
    // Local body admission against the observed 8,000-token website ceiling.
    // The reserve covers unmeasured website framing/output; this is neither a
    // provider quota guarantee nor a reason to truncate history or retry Send.
    static let groqMaximumBodyTokens = 6_000
    static let groqReservedTokens = 2_000

    static func groqPromptBudgetUsesExactTokenizer(model: String) -> Bool {
        guard let choice = WebsiteModelCatalog.choice(for: model), choice.provider == "groq" else { return false }
        return ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.8-27b"].contains(choice.key)
    }

    @discardableResult
    static func validateGroqPromptBudget(model: String, prompt: String) throws -> Int? {
        guard LocalModelCatalog.webProvider(for: model) == "groq" else { return nil }
        guard groqPromptBudgetUsesExactTokenizer(model: model) else {
            // Unknown choices and an unpinned website default retain the
            // conservative byte allowance; they cannot borrow another tokenizer.
            let bytes = prompt.utf8.count
            guard bytes <= groqMaximumBodyTokens else {
                throw Failure.groqPromptByteBudgetExceeded(actualBytes: bytes, maximumBytes: groqMaximumBodyTokens,
                                                          reservedTokens: groqReservedTokens)
            }
            return bytes
        }
        let count: Int
        do {
            if WebsiteModelCatalog.choice(for: model)?.key == "qwen/qwen3.8-27b" {
                count = try QwenBodyTokenCounter.tokenCount(prompt)
            } else {
                count = try GroqBodyTokenCounter.tokenCount(prompt)
            }
        }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure.groqTokenCounterUnavailable }
        guard count <= groqMaximumBodyTokens else {
            throw Failure.groqPromptBudgetExceeded(actualTokens: count, maximumTokens: groqMaximumBodyTokens,
                                                  reservedTokens: groqReservedTokens)
        }
        return count
    }

    struct Request: Sendable {
        let model: String
        let singleActionRelay: Bool
        /// Provider-derived transport policy, never model-authored reply text.
        let requiresEmbeddedEnvelope: Bool
        let stream: Bool
        let prompt: String
        let promptStatistics: WebsitePromptProjection.Statistics
        let runtimeInstructions: String
        let currentUserInstructions: String
        /// Derived from validated original definitions; native admission supplies state.
        let requiresBrowserToolAvailability: Bool
        let toolCatalogDiagnostic: ToolCatalogDiagnostic
        let offeredToolNames: Set<String>
        let customToolNames: Set<String>
        /// Available only for an exact registered native Groq schema loader.
        /// The server owns selection state; page/model data cannot create it.
        let groqToolCatalogSeed: GroqToolCatalog.Seed?
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
        let browserReadMode: ComputaModelToolCatalog.BrowserReadMode?
        let nativeBrowserBit: UInt16
    }

    fileprivate struct ToolPolicy: Sendable {
        let allowedNames: Set<String>
        let requiresCall: Bool
        let mode: ToolCatalogDiagnostic.Choice
    }

    /// Finite request facts only. These fields never alter model instructions,
    /// parser admission or native execution, and contain no client-authored text.
    struct ToolCatalogDiagnostic: Codable, Equatable, Sendable {
        enum Binding: String, Codable, Sendable { case unknown, unbound, bound }
        enum Choice: String, Codable, Sendable {
            case auto, none, required, selected
            case allowedAuto = "allowed_auto", allowedNone = "allowed_none", allowedRequired = "allowed_required"
        }
        // Version 1 bit positions; do not reorder without a diagnostic version change.
        static let browserNames = ["browser_tabs", "browser_open", "browser_bind", "browser_navigate",
            "browser_read", "browser_continue", "browser_click", "browser_fill", "browser_wait", "browser_close"]
        let binding: Binding
        let choice: Choice
        let offeredCount: Int
        let allowedCount: Int
        let offeredBrowserMask: UInt16
        /// tool_choice allowance only; no target/reference/permission authority.
        let allowedBrowserMask: UInt16
        let requiresCall: Bool
        let parallel: Bool
        let maxToolCalls: Int?

        fileprivate init(tools: [String: OfferedTool], policy: ToolPolicy,
                         availability: EmbeddedBrowserToolAvailability?, parallel: Bool, maxToolCalls: Int?) {
            binding = availability.map { $0 == .bound ? .bound : .unbound } ?? .unknown
            choice = policy.mode
            offeredCount = tools.count
            allowedCount = policy.allowedNames.count
            offeredBrowserMask = tools.values.reduce(0) { $0 | $1.nativeBrowserBit }
            allowedBrowserMask = tools.reduce(0) { mask, entry in
                mask | (policy.allowedNames.contains(entry.key) ? entry.value.nativeBrowserBit : 0)
            }
            requiresCall = policy.requiresCall
            self.parallel = parallel
            self.maxToolCalls = maxToolCalls
        }

        var logFields: String {
            "binding=\(binding.rawValue) choice=\(choice.rawValue) offeredCount=\(offeredCount) allowedCount=\(allowedCount) offeredBrowserMask=\(offeredBrowserMask) allowedBrowserMask=\(allowedBrowserMask) requiresCall=\(requiresCall) parallel=\(parallel) maxToolCalls=\(maxToolCalls.map(String.init) ?? "unset")"
        }
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
        case invalidBrowserReadArguments
        case unsupportedToolType
        case unsupportedModality(Modality)
        case promptTooLarge(actualBytes: Int, maximumBytes: Int)
        case groqPromptBudgetExceeded(actualTokens: Int, maximumTokens: Int, reservedTokens: Int)
        case groqPromptByteBudgetExceeded(actualBytes: Int, maximumBytes: Int, reservedTokens: Int)
        case groqTokenCounterUnavailable
        case emptyReply
        case malformedEnvelope
        case unsupportedWebsiteResponse
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
            case .invalidBrowserReadArguments: "Browser read arguments do not match the offered fresh-read or continuation contract."
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
            case let .groqPromptBudgetExceeded(actual, maximum, reserved):
                "The complete Groq website prompt uses \(actual) body tokens, exceeding the local \(maximum)-token budget with \(reserved) tokens reserved for website framing and output. No user content, history or action evidence was truncated, and no prompt was submitted. Use a model with a larger request allowance or a new shorter task."
            case let .groqPromptByteBudgetExceeded(actual, maximum, reserved):
                "This Groq model has no verified local tokenizer. Its complete prompt is \(actual) UTF-8 bytes, exceeding the conservative \(maximum)-byte allowance with \(reserved) tokens reserved for website framing and output. No content was truncated or submitted. Choose a supported model or a shorter task."
            case .groqTokenCounterUnavailable:
                "The Groq website prompt budget could not be verified. No context was truncated or submitted."
            case .emptyReply: "The website returned an empty model reply."
            case .malformedEnvelope: "The website returned a malformed model response envelope. No tool calls from this reply were dispatched."
            case .unsupportedWebsiteResponse: "ChatGPT returned website content outside the required response envelope. Computa cannot verify a native website card or action. This reply was not accepted or retried, and no local tool calls from it were dispatched."
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

    static func prepareRequest(_ data: Data,
                               browserToolAvailability: EmbeddedBrowserToolAvailability? = nil,
                               groqToolCatalogProjection: GroqToolCatalog.Projection? = nil) throws -> Request {
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
        let provider = LocalModelCatalog.webProvider(for: model)
        let isChatGPT = provider == "chatgpt", isClaude = provider == "claude", isGroq = provider == "groq"
        // DeepSeek's JSON code block preserves the literal PRE text, including
        // backslashes in patch inputs. Its ordinary paragraph renders Markdown.
        let responseFormat: ComputaAgentInstructions.WebResponseFormat = switch provider {
        case "qwen": .rawJSON
        case "claude", "deepseek": .literalFencedJSON
        default: .fencedJSON
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
        var schemas: [[String: Any]]
        var registeredDefinitions: [[String: Any]] = []
        let requiresBrowserToolAvailability: Bool
        let deferredBrowserInstructions: String?
        var toolDefinitionsChanged = false
        if let raw = object["tools"], !(raw is NSNull) {
            guard let values = raw as? [[String: Any]] else { throw Failure.invalidTools }
            registeredDefinitions = values
            var historical: [String: OfferedTool] = [:]
            for value in values {
                if value["type"] as? String == "namespace" {
                    guard let namespace = value["name"] as? String, !namespace.isEmpty,
                          let children = value["tools"] as? [[String: Any]] else { throw Failure.invalidTools }
                    for child in children { try insertTool(child, namespace: namespace, into: &historical) }
                } else { try insertTool(value, namespace: nil, into: &historical) }
            }
            requiresBrowserToolAvailability = ComputaModelToolCatalog.requiresBrowserToolAvailability(values)
            deferredBrowserInstructions = ComputaModelToolCatalog.deferredBrowserToolInstructions(values,
                availability: browserToolAvailability)
            schemas = ComputaModelToolCatalog.visibleToolDefinitions(values, modelID: model,
                browserToolAvailability: browserToolAvailability)
            toolDefinitionsChanged = !NSArray(array: values).isEqual(to: schemas)
            object["tools"] = schemas
        } else {
            schemas = []
            requiresBrowserToolAvailability = false
            deferredBrowserInstructions = nil
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
        var policy = try toolPolicy(object["tool_choice"], tools: offered)
        // Native availability and the complete callable catalog establish the
        // entry route even when its exact schema has not been loaded yet.
        let groqEntryTools = isGroq ? offered.filter {
            policy.allowedNames.contains($0.key) && $0.value.nativeBrowserBit != 0
                && ["browser_open", "browser_bind"].contains($0.value.name)
        } : [:]
        let groqToolCatalogSeed: GroqToolCatalog.Seed?
        if isGroq, GroqToolCatalog.isRegisteredLoader(registeredDefinitions) {
            let loaderAllowed = [GroqToolCatalog.name, "functions." + GroqToolCatalog.name].contains {
                policy.allowedNames.contains($0)
            }
            groqToolCatalogSeed = .init(
                registeredDefinitionsJSON: try JSONSerialization.data(withJSONObject: registeredDefinitions,
                    options: [.sortedKeys, .withoutEscapingSlashes]),
                callableNames: Set(offered.keys), allowedNames: policy.allowedNames,
                preloadNames: loaderAllowed ? [] : policy.allowedNames,
                toolChoiceJSON: try JSONSerialization.data(withJSONObject: object["tool_choice"] ?? "auto",
                    options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]))
        } else { groqToolCatalogSeed = nil }
        if let selection = groqToolCatalogProjection {
            guard let seed = groqToolCatalogSeed else { throw Failure.invalidTools }
            try GroqToolCatalog.validate(selection, for: seed)
            schemas = schemas.compactMap { definition in
                if definition["type"] as? String == "namespace", let namespace = definition["name"] as? String,
                   let children = definition["tools"] as? [[String: Any]] {
                    let selected = children.filter { child in
                        (child["name"] as? String).map { selection.selectedNames.contains(namespace + "." + $0) } ?? false
                    }.map {
                        GroqToolCatalog.restoringRegisteredLoaderBounds($0, namespace: namespace)
                    }
                    guard !selected.isEmpty else { return nil }
                    var result = definition; result["tools"] = selected; return result
                }
                guard let name = definition["name"] as? String, selection.selectedNames.contains(name) else { return nil }
                return GroqToolCatalog.restoringRegisteredLoaderBounds(definition)
            }
            object["tools"] = schemas
            toolDefinitionsChanged = true
            offered = offered.filter { selection.selectedNames.contains($0.key) }
            policy = .init(allowedNames: policy.allowedNames.intersection(offered.keys),
                           requiresCall: policy.requiresCall, mode: policy.mode)
            guard !policy.requiresCall || !policy.allowedNames.isEmpty else { throw Failure.invalidToolChoice }
        }
        let configuration = try responseConfiguration(object, schemas: schemas, parallel: parallel)
        let customNames = Set(offered.filter { $0.value.isCustom }.keys)
        let includedInstructionText = trustedInstructionText(in: object)
        let compactGroq = isGroq && groqToolCatalogProjection != nil
        var groqDomains = Set<ComputaAgentInstructions.GroqInstructionDomain>()
        for tool in offered.values where tool.namespace == nil || tool.namespace == "functions" {
            if tool.nativeBrowserBit != 0 {
                groqDomains.insert(.browser)
                switch tool.name {
                case "browser_fill", "browser_click": groqDomains.insert(.browserInput)
                case "browser_close": groqDomains.insert(.browserClose)
                default: groqDomains.insert(.browserRead)
                }
            }
            if !tool.isCustom, ["exec_command", "write_stdin"].contains(tool.name) { groqDomains.insert(.terminal) }
            if tool.isCustom, tool.name == "apply_patch" { groqDomains.insert(.files) }
            if !tool.isCustom, tool.name.hasPrefix("computer_v2_") { groqDomains.insert(.computer) }
        }
        let runtimeInstructions = compactGroq
            ? [ComputaAgentInstructions.groqRuntimeContract,
               ComputaAgentInstructions.groqNativeSupplement(includedInstructionText: includedInstructionText,
                                                            needsBrowser: requiresBrowserToolAvailability, domains: groqDomains),
               try groqToolCatalogProjection.map(groqCatalogNotice)].compactMap { $0 }.joined(separator: "\n\n")
            : [ComputaAgentInstructions.webInferenceContract(offeredFunctions: offered.mapValues(\.name),
            customToolNames: customNames, includedInstructionText: includedInstructionText, compactNativeContext: isChatGPT,
            deduplicateNativeContext: isClaude || isGroq),
            deferredBrowserInstructions].compactMap { $0 }.joined(separator: "\n\n")
        let latestUserItemIndex = (object["input"] as? [Any])?.lastIndex { item in
            guard let message = item as? [String: Any], message["role"] as? String == "user" else { return false }
            return message["type"] == nil || message["type"] as? String == "message"
        }
        let currentUserInstructions = compactGroq
            ? ComputaAgentInstructions.groqCurrentUserContract(latestUserItemIndex: latestUserItemIndex, inputIsString: object["input"] is String)
            : ComputaAgentInstructions.webCurrentUserContract(latestUserItemIndex: latestUserItemIndex, inputIsString: object["input"] is String)
        let fullDisplaySource = toolDefinitionsChanged
            ? String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            : originalJSON
        let taskDisplaySource = try groqToolCatalogProjection.map {
            try groqTrustedNativeProjection(originalJSON, object: object, schemas: $0.displaySchemas(schemas), domains: groqDomains)
        } ?? fullDisplaySource
        // API response/transport controls are validated above and retained in
        // the canonical request. They must not become website instructions to
        // supply unsupported reasoning output or transport metadata.
        let displaySource = WebsitePromptProjection.omittingAPIOnlyTopLevelFields(taskDisplaySource)
        let projection = WebsitePromptProjection.compactValidatedJSON(displaySource)
        // Groq receives one compact JSON line inside a literal code block.
        // Valid JSON strings cannot contain raw CR/LF, so quoted backticks cannot
        // become a closing-fence line. Preserve JSON lexemes rather than expand
        // punctuation into Unicode escapes; the other providers keep their
        // existing rendering policy. This grants no relay/dispatch privileges.
        let displayJSON = isGroq ? projection.json
            : displayStableJSON(isChatGPT ? projection.json : displaySource, shieldURLPunctuation: isChatGPT)
        // The eight fence bytes count toward admission and ownership fingerprints.
        let framedRequestJSON = (isChatGPT || isClaude || isGroq) ? "```\n" + displayJSON + "\n```" : displayJSON
        let requestContext = compactGroq ? ComputaAgentInstructions.groqRequestContext
            : ComputaAgentInstructions.requestContext(compactLiteralJSON: isGroq)
        let browserHandoff = compactGroq
            ? currentGroqBrowserHandoff(tools: offered, policy: policy, entryTools: groqEntryTools,
                                       availability: browserToolAvailability)
            : currentBrowserHandoff(tools: offered, policy: policy, availability: browserToolAvailability)
        let responseContract = compactGroq ? ComputaAgentInstructions.groqResponseContract(currentBrowserHandoff: browserHandoff,
            hasFunctions: offered.values.contains { !$0.isCustom }, hasCustomTools: !customNames.isEmpty,
            currentToolHandoff: try currentGroqToolHandoff(projection: groqToolCatalogProjection,
                offeredNames: Set(offered.keys), allowedNames: policy.allowedNames))
            : ComputaAgentInstructions.webResponseContract(offeredToolNames: Array(offered.keys), customToolNames: customNames,
            includedInstructionText: includedInstructionText, responseFormat: responseFormat,
            singleActionRelay: isChatGPT,
            currentBrowserHandoff: browserHandoff,
            allowedToolNames: policy.allowedNames)
        let prompt = """
        \(runtimeInstructions)

        \(requestContext)
        COMPLETE_RESPONSES_REQUEST_JSON:
        \(framedRequestJSON)
        END_COMPLETE_RESPONSES_REQUEST_JSON.

        \(currentUserInstructions)

        \(responseContract)
        """
        let bytes = prompt.utf8.count
        guard bytes <= maximumPromptBytes else {
            throw Failure.promptTooLarge(actualBytes: bytes, maximumBytes: maximumPromptBytes)
        }
        let statistics = projection.statistics(originalRequestBytes: data.count, presentedRequestBytes: displayJSON.utf8.count,
            runtimeBytes: runtimeInstructions.utf8.count, requestContextBytes: requestContext.utf8.count,
            currentUserBytes: currentUserInstructions.utf8.count, responseContractBytes: responseContract.utf8.count,
            finalPromptBytes: bytes)
        return Request(model: model, singleActionRelay: isChatGPT, requiresEmbeddedEnvelope: isChatGPT, stream: stream, prompt: prompt, promptStatistics: statistics, runtimeInstructions: runtimeInstructions,
                       currentUserInstructions: currentUserInstructions,
                       requiresBrowserToolAvailability: requiresBrowserToolAvailability,
                       toolCatalogDiagnostic: .init(tools: offered, policy: policy, availability: browserToolAvailability,
                           parallel: parallel, maxToolCalls: (object["max_tool_calls"] as? NSNumber)?.intValue),
                       offeredToolNames: Set(offered.keys), customToolNames: customNames,
                       groqToolCatalogSeed: groqToolCatalogSeed, tools: offered,
                       toolPolicy: policy, parallelToolCalls: parallel,
                       maximumToolCalls: (object["max_tool_calls"] as? NSNumber)?.intValue,
                       responseConfiguration: configuration, continuationRequest: data)
    }

    private static func groqCatalogNotice(_ projection: GroqToolCatalog.Projection) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let entries = String(decoding: try encoder.encode(projection.discoverable.map {
            [$0.name, String($0.summary.prefix(40)), $0.isCustom ? "custom" : "function"]
        }), as: UTF8.self)
        let revision = String(decoding: try encoder.encode(projection.revision), as: UTF8.self)
        let loaded = String(decoding: try encoder.encode(projection.selectedNames.sorted()), as: UTF8.self)
        let unavailable = String(decoding: try encoder.encode(projection.inventory.filter { !$0.callable }.map(\.name)), as: UTF8.self)
        let denied = String(decoding: try encoder.encode(projection.inventory.filter { $0.callable && !$0.allowed }.map(\.name)), as: UTF8.self)
        let loader = projection.inventory.first { $0.name == GroqToolCatalog.name || $0.name == "functions." + GroqToolCatalog.name }?.name
            ?? GroqToolCatalog.name
        return """
        GROQ_NATIVE_TOOL_INVENTORY:
        Catalog rows [name,purpose,kind] describe available, allowed tools. Load 1–4 choices from names.items with \(loader) and the current catalog_revision. Loading replaces optional selections and executes nothing. Only the next request after a matching receipt exposes the exact schemas. Never infer arguments or batch loading with execution.
        ```
        {"catalog_revision":\(revision),"loaded":\(loaded),"unavailable":\(unavailable),"denied":\(denied),"inventory":\(entries)}
        ```
        END_GROQ_NATIVE_TOOL_INVENTORY.
        """
    }

    /// Repeat the validated current selection at the final response boundary.
    /// Inventory summaries are discovery data, not callable schemas. An exact
    /// loader example avoids requiring the model to invent its first arguments.
    private static func currentGroqToolHandoff(projection: GroqToolCatalog.Projection?,
                                               offeredNames: Set<String>, allowedNames: Set<String>) throws -> String {
        guard let projection else { return "" }
        func json(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        let callable = offeredNames.intersection(allowedNames)
        var result = "Callable names for THIS response: \(try json(callable.sorted())). Other inventory names are not loaded schemas."
        guard let loader = callable.sorted().first(where: {
            $0 == GroqToolCatalog.name || $0 == "functions." + GroqToolCatalog.name
        }) else { return result }
        let unloaded = projection.loaderChoices.filter { !projection.selectedNames.contains($0) }
        guard let example = unloaded.first(where: { $0 == "exec_command" || $0 == "functions.exec_command" })
            ?? unloaded.first else { return result }
        let call: [String: Any] = ["type": "tool_calls", "calls": [["name": loader,
            "arguments": ["catalog_revision": projection.revision, "names": [example]]]]]
        result += " Before using an unloaded tool, request its schema with the loader alone and wait for the matching result. Do not call the unloaded tool in that response."
        result += " Example only: if the task needs the tool named in this example, first return \(try json(call)). Then read its exact schema in the next request before supplying arguments. Choose needed available, allowed inventory names; loading does not execute them."
        return result
    }

    private static func currentGroqBrowserHandoff(tools: [String: OfferedTool], policy: ToolPolicy,
                                                  entryTools: [String: OfferedTool],
                                                  availability: EmbeddedBrowserToolAvailability?) -> String {
        if availability == .unbound, !entryTools.isEmpty {
            let bind = entryTools.first { $0.value.name == "browser_bind" }.map {
                " \($0.key) needs this turn's observed tab_id."
            } ?? ""
            return "Current browser state: unbound. Page tools require successful \(entryTools.keys.sorted().joined(separator: " or ")). Load its schema if needed, then execute it; loading alone does not bind.\(bind) Wait for matching output, then use the next request's refreshed inventory and catalog_revision to load page tools. Empty tabs do not prove denied access."
        }
        let allowed = tools.filter { policy.allowedNames.contains($0.key) && $0.value.nativeBrowserBit != 0 }
        guard !allowed.isEmpty else { return "" }
        switch availability {
        case .bound:
            return "Current browser state: native page bound. Fresh browser_read needs no cursor; browser_continue requires an observed next_cursor. Use loaded exact schemas and current refs."
        default: return ""
        }
    }

    /// Native state and the final validated catalog establish this handoff,
    /// never tool-output claims or browser-shaped names in retained history.
    private static func currentBrowserHandoff(tools: [String: OfferedTool], policy: ToolPolicy,
                                              availability: EmbeddedBrowserToolAvailability?) -> String {
        let allowed = tools.filter { policy.allowedNames.contains($0.key) && $0.value.nativeBrowserBit != 0 }
        if availability == .unbound {
            let entry = allowed.filter { ["browser_tabs", "browser_open", "browser_bind"].contains($0.value.name) }
            guard !entry.isEmpty else { return "" }
            var lines = [
                "COMPUTA_CURRENT_BROWSER_ENTRY:",
                "Computa offers these permitted browser entry operations: \(entry.keys.sorted().joined(separator: ", ")). This turn has not bound a page yet.",
                "If the task needs a webpage, request the relevant browser operation. Computa executes it outside this website. A text-only reply needs no tab inventory.",
            ]
            if let open = entry.filter({ $0.value.name == "browser_open" }).keys.sorted().first {
                lines.append("For a supplied URL, request \(open) with its exact URL in the url argument, including localhost URLs. This creates and binds a task page, subject to native permissions.")
            }
            if let tabs = entry.filter({ $0.value.name == "browser_tabs" }).keys.sorted().first {
                lines.append("To inspect existing user tabs, request \(tabs) with {}. An empty inventory does not establish denied browser access.")
            }
            if let bind = entry.filter({ $0.value.name == "browser_bind" }).keys.sorted().first {
                lines.append("For an existing user tab, request \(bind) only with a matching tab_id actually observed in this turn. Never invent a tab ID or reuse a historical binding.")
            }
            lines.append("Wait for matching output and use the next request's permitted schemas. This notice proves no website outcome or existing connection; actual errors, permissions and user scope still govern.")
            return lines.joined(separator: "\n")
        }
        guard availability == .bound else { return "" }
        let closeHandoff = allowed.filter { $0.value.name == "browser_close" }.keys.sorted().first.map { close in
            "If this turn opened the current tab (matching native open output: ownership=task_created) and the task calls for closing it, request \(close) with {} before the final answer. Verify released=true and existing_user_tab_preserved=true in its matching output. A website receipt does not close a tab. Preserve existing user tabs and report an unverified close."
        }
        guard let read = allowed.filter({ $0.value.browserReadMode == .fresh }).keys.sorted().first else {
            return closeHandoff ?? ""
        }
        var lines = [
            "COMPUTA_CURRENT_BROWSER_CAPABILITIES:",
            "This request has a native browser binding. Tool_choice permits these native browser tools: \(allowed.keys.sorted().joined(separator: ", ")).",
            "For a fresh current-page observation, call \(read) with {}. No continuation cursor is required.",
            "These are Computa's local relay tools; absent website-native integrations do not make them unavailable. Actual tool errors, permissions and user scope still govern.",
        ]
        if let wait = allowed.filter({ $0.value.name == "browser_wait" }).keys.sorted().first {
            lines.append("\(wait) reports read-only readiness. After its matching output reports navigation ready, use \(read) for current page evidence and refs; readiness is not task success. Do not replay the preceding input.")
        }
        if let continuation = allowed.filter({ $0.value.name == "browser_continue" }).keys.sorted().first {
            lines.append("\(continuation) is only for a next_cursor from a current read, not a prerequisite for \(read).")
        }
        if let closeHandoff { lines.append(closeHandoff) }
        return lines.joined(separator: "\n")
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

    private enum GroqJSONPath: Hashable {
        case key(String), index(Int)
    }

    /// Replace only known native policy within independently trusted string
    /// values. Lexical edits preserve every other byte, including number/escape
    /// spellings and foreign prefixes/suffixes. Tool schema filtering is the
    /// separately authorized native catalog projection. Ambiguous duplicate
    /// keys fail closed rather than choosing which contract to present.
    private static func groqTrustedNativeProjection(_ source: String, object: [String: Any],
                                                     schemas: [[String: Any]],
                                                     domains: Set<ComputaAgentInstructions.GroqInstructionDomain>) throws -> String {
        var replacements: [[GroqJSONPath]: (String, String)] = [:]
        func consider(_ value: Any?, at path: [GroqJSONPath]) {
            guard let text = value as? String else { return }
            let compact = ComputaAgentInstructions.groqCompactTrustedNativeText(text, domains: domains)
            if Data(text.utf8) != Data(compact.utf8) { replacements[path] = (text, compact) }
        }
        consider(object["instructions"], at: [.key("instructions")])
        for (index, item) in (object["input"] as? [[String: Any]] ?? []).enumerated() {
            guard item["type"] == nil || item["type"] as? String == "message",
                  let role = item["role"] as? String, ["system", "developer"].contains(role) else { continue }
            let path: [GroqJSONPath] = [.key("input"), .index(index), .key("content")]
            consider(item["content"], at: path)
            for (partIndex, part) in (item["content"] as? [[String: Any]] ?? []).enumerated() {
                guard let type = part["type"] as? String, ["input_text", "text"].contains(type) else { continue }
                consider(part["text"], at: path + [.index(partIndex), .key("text")])
            }
        }
        let projectedTools = try JSONSerialization.data(withJSONObject: schemas, options: [.sortedKeys, .withoutEscapingSlashes])
        let bytes = Array(source.utf8)
        var position = 0, edits: [(Range<Int>, Data)] = []
        enum ScanFailure: Error { case ambiguous }
        func whitespace() { while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
        func stringRange() throws -> Range<Int> {
            guard position < bytes.count, bytes[position] == 34 else { throw ScanFailure.ambiguous }
            let start = position
            position += 1
            while position < bytes.count {
                if bytes[position] == 92 { position += 2 }
                else if bytes[position] == 34 { position += 1; return start..<position }
                else { position += 1 }
            }
            throw ScanFailure.ambiguous
        }
        func decoded(_ range: Range<Int>) throws -> String {
            guard let value = try JSONSerialization.jsonObject(with: Data(bytes[range]), options: .fragmentsAllowed) as? String
            else { throw ScanFailure.ambiguous }
            return value
        }
        func value(_ path: [GroqJSONPath], depth: Int) throws {
            whitespace()
            let start = position
            try body(path, depth: depth)
            if path == [.key("tools")] { edits.append((start..<position, projectedTools)) }
        }
        func body(_ path: [GroqJSONPath], depth: Int) throws {
            guard depth <= 256 else { throw ScanFailure.ambiguous }
            whitespace()
            guard position < bytes.count else { throw ScanFailure.ambiguous }
            switch bytes[position] {
            case 34:
                let range = try stringRange()
                if let replacement = replacements[path] {
                    guard Data(try decoded(range).utf8) == Data(replacement.0.utf8) else { throw ScanFailure.ambiguous }
                    let encoded = try groqCompactEncodedNativeString(Data(bytes[range]), decoded: replacement.0, domains: domains)
                    edits.append((range, encoded))
                }
            case 123:
                position += 1; whitespace()
                if position < bytes.count, bytes[position] == 125 { position += 1; return }
                var keys = Set<String>()
                while true {
                    whitespace()
                    let key = try decoded(stringRange())
                    guard keys.insert(key).inserted else { throw ScanFailure.ambiguous }
                    whitespace()
                    guard position < bytes.count, bytes[position] == 58 else { throw ScanFailure.ambiguous }
                    position += 1
                    try value(path + [.key(key)], depth: depth + 1)
                    whitespace()
                    guard position < bytes.count else { throw ScanFailure.ambiguous }
                    if bytes[position] == 125 { position += 1; return }
                    guard bytes[position] == 44 else { throw ScanFailure.ambiguous }
                    position += 1
                }
            case 91:
                position += 1; whitespace()
                if position < bytes.count, bytes[position] == 93 { position += 1; return }
                var index = 0
                while true {
                    try value(path + [.index(index)], depth: depth + 1); index += 1
                    whitespace()
                    guard position < bytes.count else { throw ScanFailure.ambiguous }
                    if bytes[position] == 93 { position += 1; return }
                    guard bytes[position] == 44 else { throw ScanFailure.ambiguous }
                    position += 1
                }
            default:
                let start = position
                while position < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) { position += 1 }
                guard position > start else { throw ScanFailure.ambiguous }
            }
        }
        do {
            try value([], depth: 0); whitespace()
            guard position == bytes.count else { throw Failure.invalidRequest }
        } catch { throw Failure.invalidRequest }
        var result = Data(), start = 0
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            result.append(contentsOf: bytes[start..<range.lowerBound]); result.append(replacement)
            start = range.upperBound
        }
        result.append(contentsOf: bytes[start...])
        return String(decoding: result, as: UTF8.self)
    }

    /// Map decoded UTF-8 boundaries back to the original JSON string lexeme.
    /// This preserves even foreign \u escapes around the replaced native block.
    private static func groqCompactEncodedNativeString(_ encoded: Data, decoded: String,
        domains: Set<ComputaAgentInstructions.GroqInstructionDomain>) throws -> Data {
        let raw = Array(encoded), text = Data(decoded.utf8)
        guard raw.count >= 2, raw.first == 34, raw.last == 34 else { throw Failure.invalidRequest }
        var offsets = [Int: Int](), cursor = 1, decodedOffset = 0
        offsets[0] = cursor
        while cursor < raw.count - 1 {
            let start = cursor
            if raw[cursor] == 92 {
                guard cursor + 2 <= raw.count - 1 else { throw Failure.invalidRequest }
                cursor += 2
                if raw[start + 1] == 117 {
                    guard start + 6 <= raw.count - 1 else { throw Failure.invalidRequest }
                    cursor = start + 6
                    guard let first = Int(String(decoding: raw[(start + 2)..<(start + 6)], as: UTF8.self), radix: 16) else { throw Failure.invalidRequest }
                    if (0xD800...0xDBFF).contains(first) {
                        guard cursor + 6 <= raw.count - 1, raw[cursor] == 92, raw[cursor + 1] == 117,
                              let second = Int(String(decoding: raw[(cursor + 2)..<(cursor + 6)], as: UTF8.self), radix: 16),
                              (0xDC00...0xDFFF).contains(second) else { throw Failure.invalidRequest }
                        cursor += 6
                    } else if (0xDC00...0xDFFF).contains(first) { throw Failure.invalidRequest }
                }
                let fragment = Data([34] + Array(raw[start..<cursor]) + [34])
                guard let value = try JSONSerialization.jsonObject(with: fragment, options: .fragmentsAllowed) as? String
                else { throw Failure.invalidRequest }
                decodedOffset += value.utf8.count
            } else {
                cursor += 1; decodedOffset += 1
            }
            offsets[decodedOffset] = cursor
        }
        guard decodedOffset == text.count else { throw Failure.invalidRequest }
        var result = Data([34]), offset = 0, rawOffset = 1
        while offset < text.count {
            let matches = ComputaAgentInstructions.groqNativeInstructionReplacements(domains: domains).compactMap { before, after -> (Range<Int>, Data)? in
                text.range(of: before, in: offset..<text.count).map { ($0, after) }
            }
            guard let next = matches.min(by: { lhs, rhs in
                lhs.0.lowerBound == rhs.0.lowerBound ? lhs.0.count > rhs.0.count : lhs.0.lowerBound < rhs.0.lowerBound
            }) else { break }
            guard let start = offsets[next.0.lowerBound], let end = offsets[next.0.upperBound] else { throw Failure.invalidRequest }
            result.append(contentsOf: raw[rawOffset..<start])
            let replacement = try JSONSerialization.data(withJSONObject: String(decoding: next.1, as: UTF8.self),
                options: [.fragmentsAllowed, .withoutEscapingSlashes])
            result.append(replacement.dropFirst().dropLast())
            offset = next.0.upperBound; rawOffset = end
        }
        result.append(contentsOf: raw[rawOffset...])
        return result
    }

    /// Protect rendering-sensitive punctuation in JSON strings. ChatGPT's
    /// selected message DOM was observed changing the literal request after
    /// Send; shielding . : / is a mitigation hypothesis, not a parser diagnosis.
    /// Structural JSON punctuation and decoded values remain unchanged. Other
    /// providers retain literal URL punctuation. ChatGPT keeps ASCII intraword
    /// underscores readable: between ASCII letters/digits they cannot delimit
    /// CommonMark emphasis. Edge/repeated underscores retain existing shielding.
    /// Consume complete escape pairs
    /// so quotes and literal backslashes retain their decoded values.
    private static func displayStableJSON(_ original: String, shieldURLPunctuation: Bool = false) -> String {
        let bytes = Array(original.utf8)
        var index = 0
        var result: [UInt8] = []
        result.reserveCapacity(original.utf8.count)
        let hex = Array("0123456789abcdef".utf8)
        var inString = false
        var previousLiteralAlphanumeric = false
        func appendUnicodeEscape(_ byte: UInt8) {
            result.append(contentsOf: [92, 117, 48, 48, hex[Int(byte >> 4)], hex[Int(byte & 15)]])
        }
        func asciiAlphanumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if !inString {
                result.append(byte)
                if byte == 34 { inString = true; previousLiteralAlphanumeric = false }
                continue
            }
            if byte == 34 {
                result.append(byte)
                inString = false
                previousLiteralAlphanumeric = false
                continue
            }
            if byte == 92, index < bytes.count {
                let escaped = bytes[index]
                index += 1
                previousLiteralAlphanumeric = false
                if escaped == 47 {
                    if shieldURLPunctuation { appendUnicodeEscape(escaped) }
                    else { result.append(escaped) }
                }
                else if escaped == 34 || escaped == 92 { appendUnicodeEscape(escaped) }
                else {
                    result.append(byte); result.append(escaped)
                    // Validated JSON's Unicode escape is one token. Its hex
                    // tail must not become a literal identifier neighbor.
                    if escaped == 117 {
                        result.append(contentsOf: bytes[index..<(index + 4)])
                        index += 4
                    }
                }
            } else if shieldURLPunctuation && byte == 95 && previousLiteralAlphanumeric && index < bytes.count
                        && asciiAlphanumeric(bytes[index]) {
                result.append(byte)
            } else if shieldURLPunctuation && [46, 47, 58].contains(byte)
                        || (33...44).contains(byte) || (59...64).contains(byte)
                        || (91...96).contains(byte) || (123...126).contains(byte) {
                appendUnicodeEscape(byte)
            } else {
                result.append(byte)
            }
            if byte != 92 { previousLiteralAlphanumeric = asciiAlphanumeric(byte) }
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// ChatGPT must use the complete envelope: native website cards can mix
    /// controls and suggestions into rendered prose. Other providers retain
    /// ordinary-text compatibility; prose never grants an action. Never extract
    /// or repair a call hidden inside surrounding text.
    static func parseEmbeddedReply(_ text: String, request: Request) throws -> Reply {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyReply }
        if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "{}")) == nil,
           !trimmed.contains("```"), !trimmed.hasPrefix("["), !trimmed.hasPrefix("\"") {
            // This previously accepted prose is not a JSON format correction:
            // a website-native action may have happened outside host history.
            // Do not resend its request automatically.
            guard !request.requiresEmbeddedEnvelope else { throw Failure.unsupportedWebsiteResponse }
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
        websiteSelectionEvidence: WebsiteSelectionEvidence? = nil,
        websiteToolSelection: String? = nil
    ) throws -> Data {
        guard websiteModelEvidence == nil || websiteSelectionEvidence == nil else { throw Failure.invalidRequest }
        let selectionEvidence = websiteSelectionEvidence ?? websiteModelEvidence.map(WebsiteSelectionEvidence.model)
        _ = try validated(reply, request: request)
        let output = outputItems(for: reply, responseID: responseID)
        let initial = response(request: request, reply: reply, responseID: responseID, createdAt: createdAt, output: [], completed: false, websiteSelectionEvidence: selectionEvidence, websiteToolSelection: websiteToolSelection)
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
        let completed = response(request: request, reply: reply, responseID: responseID, createdAt: createdAt, output: output, completed: true, websiteSelectionEvidence: selectionEvidence, websiteToolSelection: websiteToolSelection)
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
        websiteSelectionEvidence: WebsiteSelectionEvidence? = nil,
        websiteToolSelection: String? = nil
    ) throws -> Data {
        guard websiteModelEvidence == nil || websiteSelectionEvidence == nil else { throw Failure.invalidRequest }
        let selectionEvidence = websiteSelectionEvidence ?? websiteModelEvidence.map(WebsiteSelectionEvidence.model)
        _ = try validated(reply, request: request)
        return try JSONSerialization.data(withJSONObject: response(
            request: request, reply: reply, responseID: responseID, createdAt: createdAt,
            output: outputItems(for: reply, responseID: responseID), completed: true, websiteSelectionEvidence: selectionEvidence, websiteToolSelection: websiteToolSelection
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
                          let arguments = try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any] else {
                        throw Failure.argumentsMustBeObject
                    }
                    if let mode = tool.browserReadMode {
                        if mode == .fresh, arguments["cursor"] != nil { throw Failure.invalidBrowserReadArguments }
                        do { try EmbeddedBrowserTools.validate(tool: tool.name, arguments: arguments) }
                        catch { throw Failure.invalidBrowserReadArguments }
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
        guard let raw, !(raw is NSNull) else { return .init(allowedNames: allNames, requiresCall: false, mode: .auto) }
        if let mode = raw as? String {
            switch mode {
            case "auto": return .init(allowedNames: allNames, requiresCall: false, mode: .auto)
            case "none": return .init(allowedNames: [], requiresCall: false, mode: .none)
            case "required":
                guard !allNames.isEmpty else { throw Failure.invalidToolChoice }
                return .init(allowedNames: allNames, requiresCall: true, mode: .required)
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
            return .init(allowedNames: mode == "none" ? [] : Set(names), requiresCall: mode == "required",
                mode: mode == "none" ? .allowedNone : mode == "required" ? .allowedRequired : .allowedAuto)
        }
        return .init(allowedNames: [try toolName(choice)], requiresCall: true, mode: .selected)
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
        let readMode = type == "function" ? (schema["parameters"] as? [String: Any]).flatMap {
            ComputaModelToolCatalog.browserReadMode(name: name, namespace: namespace, schema: $0)
        } : nil
        let browserBit = ComputaModelToolCatalog.nativeBrowserToolName(schema, namespace: namespace)
            .flatMap { ToolCatalogDiagnostic.browserNames.firstIndex(of: $0) }.map { UInt16(1) << $0 } ?? 0
        tools[offeredName] = OfferedTool(name: name, namespace: namespace, isCustom: type == "custom",
            browserReadMode: readMode, nativeBrowserBit: browserBit)
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

    private static func response(request: Request, reply: Reply, responseID: String, createdAt: Int, output: [[String: Any]], completed: Bool, websiteSelectionEvidence: WebsiteSelectionEvidence? = nil, websiteToolSelection: String? = nil) -> [String: Any] {
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
        if let websiteSelectionEvidence {
            metadata = websiteSelectionEvidence.responseMetadata(preserving: metadata)
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

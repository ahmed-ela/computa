import Foundation
import CoreFoundation

/// Credentials enter only this native HTTP boundary. Redirects, cookies,
/// credential storage and application-level retries are deliberately disabled.
final class APIProviderHTTPClient: @unchecked Sendable {
    enum Failure: String, Error, LocalizedError, Sendable {
        case invalidEndpoint, missingCredential, unauthorized, rateLimited, providerBusy, timeout, modelNotFound, contextLimit, invalidRequest
        case redirectRejected, unavailable, invalidResponse, responseTooLarge, cancelled
        case invalidMessages, invalidTools, invalidToolChoice, invalidParallelToolCalls, invalidReasoningEffort, invalidClearThinking
        case invalidMaxCompletionTokens, invalidStreamOptions, invalidStream, invalidChoiceCount, invalidResponseFormat, invalidModel, invalidTemperature, invalidTopP
        var errorDescription: String? {
            if let parameter = rejectedParameter {
                return "The API provider rejected the \(parameter) parameter. No request was replayed."
            }
            return switch self {
            case .modelNotFound: "The API provider does not offer the selected model. Refresh its model list."
            case .contextLimit: "The API request exceeds this model's context limit."
            case .invalidRequest: "The API provider rejected the request format. No request was replayed."
            case .invalidEndpoint: "The API endpoint must use HTTPS, or HTTP on a literal loopback address."
            case .missingCredential: "Save an API key for this provider in Settings."
            case .unauthorized: "The API provider rejected its credentials. Check the key in Settings."
            case .rateLimited: "The API provider rate limit was reached. No request was replayed."
            case .providerBusy: "The API provider is busy because of high traffic. Try again shortly. No request was replayed."
            case .timeout: "The API provider request timed out. No request was replayed."
            case .redirectRejected: "The API provider redirected its request. Credentials were not forwarded."
            case .unavailable: "The API provider request failed. No request was replayed."
            case .invalidResponse: "The API provider returned an invalid response."
            case .responseTooLarge: "The API provider response exceeded the local size limit."
            case .cancelled: "The API provider request was cancelled."
            default: "The API provider rejected the request format. No request was replayed."
            }
        }

        /// Only constants from the request contract reach error/UI projection.
        var rejectedParameter: String? {
            switch self {
            case .invalidMessages: "messages"
            case .invalidTools: "tools"
            case .invalidToolChoice: "tool_choice"
            case .invalidParallelToolCalls: "parallel_tool_calls"
            case .invalidReasoningEffort: "reasoning_effort"
            case .invalidClearThinking: "clear_thinking"
            case .invalidMaxCompletionTokens: "max_completion_tokens"
            case .invalidStreamOptions: "stream_options"
            case .invalidStream: "stream"
            case .invalidChoiceCount: "n"
            case .invalidResponseFormat: "response_format"
            case .invalidModel: "model"
            case .invalidTemperature: "temperature"
            case .invalidTopP: "top_p"
            default: nil
            }
        }
    }

    struct Result: Sendable { let body: Data; let contentType: String }
    struct RejectionDiagnostic: Codable, Sendable {
        let httpStatus: Int
        let modelID: String?
        let envelope: String
        let error: Fields?
        let details: [Fields]
        let requestSummary: RequestSummary?
        struct Fields: Codable, Sendable { let message: String?; let type: String?; let code: String?; let param: String? }
        struct RequestSummary: Codable, Sendable {
            struct Options: Codable, Sendable {
                let n: Int?, stream: Bool?, reasoningEffort: String?, maxCompletionTokens: Int?, parallelToolCalls: Bool?, clearThinking: Bool?
            }
            let options: Options
            let messageRoleCounts: [String: Int]
            let emptyContentCount: Int
            let totalTextUTF8Bytes: Int
            let toolCount: Int
            let schemaKeywordCounts: [String: Int]
            let schemaAnalysisComplete: Bool
        }
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private let session: URLSession
    private let delegate = NoRedirects()
    static let maximumResponseBytes = 8 * 1_024 * 1_024

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    static func endpoint(_ base: URL, path: String) throws -> URL {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.scheme == "https" || c.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host),
              c.percentEncodedPath.range(of: #"(?i)%2f|%5c|%2e"#, options: .regularExpression) == nil,
              !c.path.split(separator: "/").contains(".."), !c.path.contains("\\"),
              ["models", "chat/completions", "responses"].contains(path) else { throw Failure.invalidEndpoint }
        c.path = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        c.path = "/" + (c.path.isEmpty ? "" : c.path + "/") + path
        guard let url = c.url else { throw Failure.invalidEndpoint }
        return url
    }

    func request(provider: APIProviderDefinition, key: String, path: String, body: Data?, modelID: String? = nil,
                 onRejection: (@Sendable (RejectionDiagnostic) -> Void)? = nil) async throws -> Result {
        let url = try Self.endpoint(provider.baseURL, path: path)
        guard !key.isEmpty, key.utf8.count <= 16_384,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.missingCredential }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url else { throw Failure.invalidResponse }
            switch http.statusCode {
            case 200...299: break
            case 300...399: throw Failure.redirectRejected
            case 401, 403: throw Failure.unauthorized
            case 429: break
            case 404: throw Failure.modelNotFound
            case 400, 413, 422: break
            default: throw Failure.unavailable
            }
            if http.statusCode == 429, http.expectedContentLength > 16_384 { throw Failure.rateLimited }
            guard http.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw Failure.responseTooLarge }
            var data = Data()
            let maximum = http.statusCode >= 400 ? 16_384 : Self.maximumResponseBytes
            for try await byte in bytes {
                guard data.count < maximum else {
                    if http.statusCode == 429 { throw Failure.rateLimited }
                    throw Failure.responseTooLarge
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            if http.statusCode >= 400 {
                if let onRejection { onRejection(Self.rejectionDiagnostic(status: http.statusCode, body: data, modelID: modelID, key: key, requestBody: body)) }
                if http.statusCode == 429 { throw Self.rateLimitFailure(body: data) }
                throw Self.rejectedRequest(status: http.statusCode, body: data)
            }
            return Result(body: data, contentType: http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "")
        } catch let error as Failure { throw error }
        catch is CancellationError { throw Failure.cancelled }
        catch let error as URLError {
            switch error.code {
            case .timedOut: throw Failure.timeout
            case .cancelled: throw Failure.cancelled
            default: throw Failure.unavailable
            }
        } catch { throw Failure.unavailable }
    }

    /// Capacity and account throttling both use HTTP 429. Keep the cause finite;
    /// arbitrary vendor text never enters the normal error or model transcript.
    static func rateLimitFailure(body: Data) -> Failure {
        guard body.count <= 16_384,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return .rateLimited }
        let value = object["error"] ?? object
        let fields = value as? [String: Any]
        for key in ["code", "type"] {
            if let code = fields?[key] as? String,
               ["overloaded", "overloaded_error", "server_overloaded", "model_overloaded", "capacity_exceeded"].contains(code) {
                return .providerBusy
            }
        }
        let message = (fields?["message"] as? String) ?? (value as? String)
        if message == "We're experiencing high traffic right now! Please try again soon." { return .providerBusy }
        return .rateLimited
    }

    /// Classify bounded, untrusted validation errors without retaining their text,
    /// values, paths, credentials, or request data. Unknown formats stay generic.
    static func rejectedRequest(status: Int, body: Data) -> Failure {
        if status == 413 { return .contextLimit }
        guard [400, 422].contains(status), body.count <= 16_384,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return .invalidRequest }
        let envelope = object["error"] ?? object
        let error: [String: Any]
        if let fields = envelope as? [String: Any] { error = fields }
        else if let message = envelope as? String { error = ["message": message] }
        else { return .invalidRequest }
        let codes = [error["code"] as? String, error["type"] as? String].compactMap { $0 }.filter { $0.utf8.count <= 128 }
        if codes.contains(where: { ["context_length_exceeded", "context_window_exceeded", "context_limit_exceeded", "max_tokens_exceeded"].contains($0) }) { return .contextLimit }
        let parameters: [(String, Failure)] = [
            ("messages", .invalidMessages), ("tools", .invalidTools), ("tool_choice", .invalidToolChoice),
            ("parallel_tool_calls", .invalidParallelToolCalls), ("reasoning_effort", .invalidReasoningEffort),
            ("clear_thinking", .invalidClearThinking), ("max_completion_tokens", .invalidMaxCompletionTokens),
            ("max_tokens", .invalidMaxCompletionTokens), ("stream_options", .invalidStreamOptions),
            ("stream", .invalidStream), ("n", .invalidChoiceCount), ("response_format", .invalidResponseFormat),
            ("model", .invalidModel), ("temperature", .invalidTemperature), ("top_p", .invalidTopP)
        ]
        if let parameter = error["param"] as? String, parameter.utf8.count <= 256,
           parameter.range(of: #"^[a-z_]+(?:(?:\.[A-Za-z_][A-Za-z_0-9]*|\.[0-9]+|\[[0-9]+\]))*$"#, options: .regularExpression) != nil {
            let root = parameter.prefix { $0 != "." && $0 != "[" }
            if let match = parameters.first(where: { $0.0 == root }) { return match.1 }
        }
        for (parameter, failure) in parameters {
            if codes.contains(where: { ["invalid_" + parameter, "unsupported_" + parameter, parameter + "_invalid", parameter + "_not_supported"].contains($0) }) { return failure }
        }
        guard let message = error["message"] as? String, message.utf8.count <= 4_096 else { return .invalidRequest }
        let prefix = message.lowercased()
        for (parameter, failure) in parameters {
            let quoted = ["'" + parameter + "'", "\"" + parameter + "\"", "`" + parameter + "`"]
            var beginnings: [String] = []
            for name in quoted {
                beginnings.append("invalid value for \(name):")
                beginnings.append("invalid parameter: \(name)")
                beginnings.append("unsupported parameter: \(name)")
                beginnings.append("unknown parameter: \(name)")
                beginnings.append("unrecognized request argument supplied: \(name)")
            }
            beginnings += ["invalid \(parameter):", "unsupported \(parameter):", "\(parameter) is not supported", "\(parameter) must be "]
            if beginnings.contains(where: prefix.hasPrefix) { return failure }
        }
        return .invalidRequest
    }

    /// Created only for an explicitly armed request. Never copies arbitrary response
    /// objects: validation input/ctx, headers, and request content have no output path.
    static func rejectionDiagnostic(status: Int, body: Data, modelID: String?, key: String, requestBody: Data? = nil) -> RejectionDiagnostic {
        func clean(_ value: Any?) -> String? {
            guard var text = value as? String else { return nil }
            if !key.isEmpty { text = text.replacingOccurrences(of: key, with: "[REDACTED]") }
            for pattern in [#"(?im)authorization\s*[:=]\s*[^\r\n]*"#, #"(?i)bearer\s+[^\s\"'<>]+"#, #"(?i)csk-[A-Za-z0-9._~+/=-]+"#] {
                text = text.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
            }
            var bounded = "", count = 0
            for scalar in text.unicodeScalars {
                let next = String(scalar)
                guard count + next.utf8.count <= 2_048 else { break }
                bounded += next; count += next.utf8.count
            }
            return bounded
        }
        func fields(_ object: [String: Any]) -> RejectionDiagnostic.Fields {
            .init(message: clean(object["message"] ?? object["msg"]), type: clean(object["type"]), code: clean(object["code"]), param: clean(object["param"]))
        }
        var shape = "non_json", projected: RejectionDiagnostic.Fields?, details: [RejectionDiagnostic.Fields] = []
        if body.count > 16_384 { shape = "oversized" }
        else if let raw = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
            var value: Any = raw
            if let object = raw as? [String: Any] {
                if let wrapped = object["error"] { value = wrapped; shape = "wrapped" }
                else { shape = "bare" }
            } else { shape = "other_json" }
            if let object = value as? [String: Any] {
                shape += "_object"; projected = fields(object)
                let rawDetails: [[String: Any]]
                if let rows = object["detail"] as? [[String: Any]] { rawDetails = Array(rows.prefix(8)) }
                else if let row = object["detail"] as? [String: Any] { rawDetails = [row] }
                else { rawDetails = [] }
                details = rawDetails.map { row in
                    var selected = row
                    // Preserve only finite request-root location, never arbitrary JSON
                    // property names or user values embedded in validation locations.
                    if selected["param"] == nil, let location = row["loc"] as? [Any], location.count <= 8 {
                        let parts = location.compactMap { $0 as? String }
                        let roots = ["messages", "tools", "tool_choice", "parallel_tool_calls", "reasoning_effort", "clear_thinking", "max_completion_tokens", "max_tokens", "stream_options", "stream", "n", "response_format", "model", "temperature", "top_p"]
                        let candidate = parts.first == "body" ? parts.dropFirst().first : parts.first
                        if let candidate, roots.contains(candidate) { selected["param"] = candidate }
                    }
                    return fields(selected)
                }
                if projected?.message == nil, let text = object["detail"] as? String {
                    projected = .init(message: clean(text), type: projected?.type, code: projected?.code, param: projected?.param)
                }
            } else if let text = value as? String { shape += "_string"; projected = .init(message: clean(text), type: nil, code: nil, param: nil) }
        }
        let boundedModel = clean(modelID).map { String($0.prefix(256)) }
        let summary = requestSummary(requestBody)
        var result = RejectionDiagnostic(httpStatus: status, modelID: boundedModel, envelope: shape, error: projected, details: details, requestSummary: summary)
        // Keep the entire encoded diagnostic below 7 KiB, leaving room for the
        // private capture's native identity fields within its 8 KiB record limit.
        while ((try? JSONEncoder().encode(result).count) ?? Int.max) > 7_168 {
            if !details.isEmpty { details.removeLast() }
            else if let value = projected {
                func half(_ text: String?) -> String? { text.map { String($0.prefix($0.count / 2)) } }
                projected = .init(message: half(value.message), type: half(value.type), code: half(value.code), param: half(value.param))
            } else { break }
            result = .init(httpStatus: status, modelID: boundedModel, envelope: shape, error: projected, details: details, requestSummary: summary)
        }
        return result
    }

    private static func requestSummary(_ data: Data?) -> RejectionDiagnostic.RequestSummary? {
        guard let data, data.count <= 2_000_000,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func integer(_ key: String) -> Int? {
            guard let value = body[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
                  (0...10_000_000).contains(value.doubleValue) else { return nil }; return value.intValue
        }
        func boolean(_ key: String) -> Bool? {
            guard let value = body[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }; return value.boolValue
        }
        let effort = body["reasoning_effort"] as? String
        let options = RejectionDiagnostic.RequestSummary.Options(n: integer("n"), stream: boolean("stream"),
            reasoningEffort: effort.flatMap { ["none", "low", "medium", "high", "xhigh", "minimal"].contains($0) ? $0 : nil },
            maxCompletionTokens: integer("max_completion_tokens"), parallelToolCalls: boolean("parallel_tool_calls"), clearThinking: boolean("clear_thinking"))
        var roles = ["system": 0, "developer": 0, "user": 0, "assistant": 0, "tool": 0, "unknown": 0], empty = 0, bytes = 0
        for message in body["messages"] as? [[String: Any]] ?? [] {
            let role = message["role"] as? String ?? "unknown"
            roles[roles[role] == nil ? "unknown" : role, default: 0] += 1
            if let text = message["content"] as? String { bytes += text.utf8.count; if text.isEmpty { empty += 1 } }
            else if let parts = message["content"] as? [[String: Any]] {
                var nonempty = false
                for part in parts {
                    if ["text", "input_text", "output_text"].contains(part["type"] as? String ?? ""), let text = part["text"] as? String {
                        bytes += text.utf8.count; nonempty = nonempty || !text.isEmpty
                    } else { nonempty = true }
                }
                if !nonempty { empty += 1 }
            } else if message["content"] == nil || message["content"] is NSNull { empty += 1 }
        }
        let tools = body["tools"] as? [[String: Any]] ?? []
        let keywords: Set<String> = ["type", "properties", "required", "additionalProperties", "items", "enum", "const", "anyOf", "oneOf", "allOf", "$ref", "$defs", "definitions", "pattern", "format", "minLength", "maxLength", "minimum", "maximum", "minItems", "maxItems", "description"]
        var counts: [String: Int] = [:], nodes = 0, complete = true
        func visit(_ schema: [String: Any], depth: Int) {
            guard depth <= 32, nodes < 4_096 else { complete = false; return }; nodes += 1
            for key in schema.keys where keywords.contains(key) { counts[key, default: 0] += 1 }
            for key in ["properties", "$defs", "definitions"] {
                for child in (schema[key] as? [String: Any] ?? [:]).values { if let object = child as? [String: Any] { visit(object, depth: depth + 1) } }
            }
            for key in ["items", "additionalProperties"] { if let child = schema[key] as? [String: Any] { visit(child, depth: depth + 1) } }
            for key in ["anyOf", "oneOf", "allOf"] { for child in schema[key] as? [[String: Any]] ?? [] { visit(child, depth: depth + 1) } }
        }
        for tool in tools { if let function = tool["function"] as? [String: Any], let schema = function["parameters"] as? [String: Any] { visit(schema, depth: 0) } }
        return .init(options: options, messageRoleCounts: roles, emptyContentCount: empty, totalTextUTF8Bytes: bytes,
                     toolCount: tools.count, schemaKeywordCounts: counts, schemaAnalysisComplete: complete)
    }

    func listModels(provider: APIProviderDefinition, key: String) async throws -> [APIModelDefinition] {
        let result = try await request(provider: provider, key: key, path: "models", body: nil)
        guard let object = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
              let rows = object["data"] as? [[String: Any]], rows.count <= 2_048 else { throw Failure.invalidResponse }
        var ids = Set<String>(), models: [APIModelDefinition] = []
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 512,
                  id == id.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  ids.insert(id).inserted else { throw Failure.invalidResponse }
            let known = APIProviderCatalog.discoveredModel(id: id, provider: provider)
            let context = (row["context_length"] as? Int) ?? (row["context_window"] as? Int) ?? known.contextWindow
            guard (1...10_000_000).contains(context) else { throw Failure.invalidResponse }
            models.append(APIModelDefinition(id: id, name: known.name, contextWindow: context, supportsImages: known.supportsImages, supportsToolImages: known.supportsToolImages))
        }
        return models
    }
}

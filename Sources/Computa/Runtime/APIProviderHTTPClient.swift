import Foundation

/// Credentials enter only this native HTTP boundary. Redirects, cookies,
/// credential storage and application-level retries are deliberately disabled.
final class APIProviderHTTPClient: @unchecked Sendable {
    enum Failure: String, Error, LocalizedError, Sendable {
        case invalidEndpoint, missingCredential, unauthorized, rateLimited, timeout, modelNotFound, contextLimit, invalidRequest
        case redirectRejected, unavailable, invalidResponse, responseTooLarge, cancelled
        var errorDescription: String? {
            switch self {
            case .modelNotFound: "The API provider does not offer the selected model. Refresh its model list."
            case .contextLimit: "The API request exceeds this model's context limit."
            case .invalidRequest: "The API provider rejected the request format. No request was replayed."
            case .invalidEndpoint: "The API endpoint must use HTTPS, or HTTP on a literal loopback address."
            case .missingCredential: "Save an API key for this provider in Settings."
            case .unauthorized: "The API provider rejected its credentials. Check the key in Settings."
            case .rateLimited: "The API provider rate limit was reached. No request was replayed."
            case .timeout: "The API provider request timed out. No request was replayed."
            case .redirectRejected: "The API provider redirected its request. Credentials were not forwarded."
            case .unavailable: "The API provider request failed. No request was replayed."
            case .invalidResponse: "The API provider returned an invalid response."
            case .responseTooLarge: "The API provider response exceeded the local size limit."
            case .cancelled: "The API provider request was cancelled."
            }
        }
    }

    struct Result: Sendable { let body: Data; let contentType: String }
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

    func request(provider: APIProviderDefinition, key: String, path: String, body: Data?) async throws -> Result {
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
            case 429: throw Failure.rateLimited
            case 404: throw Failure.modelNotFound
            case 400, 413, 422: break
            default: throw Failure.unavailable
            }
            guard http.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw Failure.responseTooLarge }
            var data = Data()
            let maximum = http.statusCode >= 400 ? 16_384 : Self.maximumResponseBytes
            for try await byte in bytes {
                guard data.count < maximum else { throw Failure.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            if http.statusCode >= 400 {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let error = object?["error"] as? [String: Any]
                let codes = [error?["code"] as? String, error?["type"] as? String].compactMap { $0 }
                if http.statusCode == 413 || codes.contains(where: { ["context_length_exceeded", "context_window_exceeded", "context_limit_exceeded", "max_tokens_exceeded"].contains($0) }) { throw Failure.contextLimit }
                throw Failure.invalidRequest
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

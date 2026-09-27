@preconcurrency import Foundation

/// A bounded availability check, not proof that the advertised model is loaded
/// or that inference will succeed. It never starts, downloads, or switches models.
enum LocalModelServerPreflight {
    enum Failure: LocalizedError, Equatable {
        case unsupportedConfiguration
        case timedOut
        case unavailable
        case httpStatus(Int)
        case invalidResponse
        case modelNotAdvertised

        var errorDescription: String? {
            switch self {
            case .unsupportedConfiguration:
                "The local model endpoint could not be safely checked. Mactopus requires an unauthenticated loopback inference endpoint. Review its provider configuration, then retry; no prompt was sent."
            case .timedOut:
                "The local model readiness check did not finish within two seconds. Check the local inference server and selected model, then retry; no prompt was sent."
            case .unavailable:
                "The local model server could not be reached. Check the selected inference backend and model, then retry; no prompt was sent."
            case .httpStatus(let status):
                "The local model server returned HTTP \(status) during its availability check. Check the selected inference backend, then retry; no prompt was sent."
            case .invalidResponse:
                "The local model server returned an invalid model list. Check the selected inference endpoint, then retry; no prompt was sent."
            case .modelNotAdvertised:
                "The local inference server is reachable, but it does not advertise this task's selected model. Make that exact model available, then retry; no model was switched and no prompt was sent."
            }
        }
    }

    /// Mirrors the pinned model-provider-info create_oss_provider.
    /// Its merge_configured_model_providers uses entry.or_insert for lmstudio:
    /// a same-name config/read override is ignored by that runtime, so it is
    /// NOT an authoritative endpoint. Capture these values at child launch.
    static func endpoint(launchEnvironment: [String: String]) throws -> URL {
        let base: String
        if let value = launchEnvironment["CODEX_OSS_BASE_URL"], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = value
        } else {
            let port = launchEnvironment["CODEX_OSS_PORT"].flatMap(UInt16.init) ?? 1234
            base = "http://localhost:\(port)/v1"
        }
        guard var components = URLComponents(string: base),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(components.host?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port == nil || (1...65535).contains(components.port!) else {
            throw Failure.unsupportedConfiguration
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.path += "/models"
        guard let url = components.url else { throw Failure.unsupportedConfiguration }
        return url
    }

    static func validateModels(_ data: Data, status: Int, modelID: String) throws {
        guard status == 200 else { throw Failure.httpStatus(status) }
        guard data.count <= 1_048_576,
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = response["data"] as? [[String: Any]], models.count <= 4_096,
              models.allSatisfy({ ($0["id"] as? String)?.isEmpty == false }) else {
            throw Failure.invalidResponse
        }
        guard models.contains(where: { $0["id"] as? String == modelID }) else { throw Failure.modelNotAdvertised }
    }

    static func check(
        endpoint: URL, modelID: String, timeout: TimeInterval,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) async throws {
        guard timeout > 0 else { throw Failure.timedOut }
        let settings = sessionConfiguration
        settings.timeoutIntervalForRequest = timeout
        settings.timeoutIntervalForResource = timeout
        settings.httpCookieStorage = nil
        settings.urlCache = nil
        settings.httpShouldSetCookies = false
        let session = URLSession(configuration: settings, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
            try validateModels(data, status: http.statusCode, modelID: modelID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch let error as URLError where error.code == .timedOut {
            throw Failure.timedOut
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Failure.unavailable
        }
    }

    /// A loopback server cannot redirect this read to a remote or authenticated
    /// destination. The 3xx response is reported without exposing its body.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

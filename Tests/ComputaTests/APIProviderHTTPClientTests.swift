import Foundation
import XCTest
@testable import Computa

final class APIProviderHTTPClientTests: XCTestCase {
    private static let roleMessage = "developer is not one of ['system', 'assistant', 'user', 'tool', 'function']"
    private static let rawError = #"{"error":{"code":"invalid_parameter_error","param":null,"message":"developer is not one of ['system', 'assistant', 'user', 'tool', 'function']","type":"invalid_request_error"},"id":"chatcmpl-fixture"}"#

    private func event(_ json: String? = nil, ending: String = "\n") -> Data {
        Data(("data: " + (json ?? Self.rawError) + ending + ending).utf8)
    }

    func testExactSingleErrorSSEAndJSONClassifyDeveloperRoleWithoutExposingVendorText() throws {
        for body in [event(), event(ending: "\r\n"), Data(Self.rawError.utf8)] {
            for status in [400, 422] {
                let failure = APIProviderHTTPClient.rejectedRequest(status: status, body: body)
                XCTAssertEqual(failure, .invalidMessages)
                XCTAssertEqual(failure.rejectedParameter, "messages")
                XCTAssertFalse(failure.localizedDescription.contains("developer"))
                XCTAssertTrue(failure.localizedDescription.contains("No request was replayed"))
            }
            let report = APIProviderHTTPClient.rejectionDiagnostic(status: 400, body: body, modelID: "fixture", key: "fixture-secret")
            XCTAssertEqual(report.error?.message, Self.roleMessage)
            XCTAssertEqual(report.error?.code, "invalid_parameter_error")
            XCTAssertNil(report.error?.param)
            XCTAssertEqual(report.envelope, body == Data(Self.rawError.utf8) ? "wrapped_object" : "sse_wrapped_object")
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("chatcmpl-fixture"))
        }
        XCTAssertEqual(APIProviderHTTPClient.rejectedRequest(status: 200, body: event()), .invalidRequest)
        XCTAssertNil(APIProviderHTTPClient.rejectionDiagnostic(status: 200, body: event(), modelID: nil, key: "").error)
    }

    func testMalformedMultipleConflictingAndSuccessSSEStayGeneric() throws {
        let valid = String(decoding: event(), as: UTF8.self)
        let invalid: [Data] = [
            Data(valid.dropLast().utf8), // Missing the event terminator.
            Data((valid + valid).utf8),
            Data((valid + "data: [DONE]\n\n").utf8),
            Data(("data: {\"choices\":[]}\n\n" + valid).utf8),
            Data(("event: error\n" + valid).utf8),
            Data((": comment\n" + valid).utf8),
            Data(("Vendor said " + valid).utf8),
            Data(valid.replacingOccurrences(of: "\n", with: "\r").utf8),
            Data("data: [DONE]\n\n".utf8), event("[]"), event("{malformed}"),
            event(Self.rawError.replacingOccurrences(of: #""id":"chatcmpl-fixture""#, with: #""choices":[]"#)),
            event(Self.rawError.replacingOccurrences(of: #""id":"chatcmpl-fixture""#, with: #""id":"chatcmpl-fixture","choices":[]"#)),
            event(Self.rawError.replacingOccurrences(of: #""param":null"#, with: #""param":null,"input":"PRIVATE_CONTENT""#)),
            event(Self.rawError.replacingOccurrences(of: #""param":null"#, with: #""param":null,"param":null"#)),
            event(Self.rawError.replacingOccurrences(of: #""code":"invalid_parameter_error""#, with: #""code":false"#)),
            event(Self.rawError.replacingOccurrences(of: #""param":null"#, with: #""param":[]"#)),
            event(Self.rawError.replacingOccurrences(of: #""id":"chatcmpl-fixture""#, with: #""id":42"#)),
            Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0xFF, 0x0A, 0x0A]),
            event(Self.rawError.replacingOccurrences(of: Self.roleMessage, with: String(repeating: "x", count: 4_097))),
            Data(repeating: 65, count: 16_385),
        ]
        for (index, body) in invalid.enumerated() {
            XCTAssertEqual(APIProviderHTTPClient.rejectedRequest(status: 400, body: body), .invalidRequest, "case \(index)")
            let report = APIProviderHTTPClient.rejectionDiagnostic(status: 400, body: body, modelID: nil, key: "fixture-secret")
            XCTAssertNil(report.error, "case \(index)")
            XCTAssertTrue(report.details.isEmpty, "case \(index)")
            XCTAssertEqual(report.envelope, body.count > 16_384 ? "oversized" : "non_json", "case \(index)")
        }
    }

    func testDeveloperRoleClassificationRequiresExactFiniteValidationTuple() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.rawError.utf8)) as? [String: Any])
        let original = try XCTUnwrap(object["error"] as? [String: Any])
        let mutations: [(String, Any)] = [
            ("message", "Quoted: " + Self.roleMessage), ("message", Self.roleMessage + " extra"),
            ("code", "other_code"), ("type", "other_type"), ("param", "unrecognized"),
            ("extra", true),
        ]
        for (field, value) in mutations {
            var changed = original; changed[field] = value
            let bytes = try JSONSerialization.data(withJSONObject: ["error": changed])
            for body in [bytes, event(String(decoding: bytes, as: UTF8.self))] {
                XCTAssertEqual(APIProviderHTTPClient.rejectedRequest(status: 400, body: body), .invalidRequest, field)
            }
        }
        let duplicate = Self.rawError.replacingOccurrences(of: #""param":null"#, with: #""param":"conflicting","param":null"#)
        XCTAssertEqual(APIProviderHTTPClient.rejectedRequest(status: 400, body: Data(duplicate.utf8)), .invalidRequest)
    }

    func testSSEPrivateDiagnosticUsesExistingSecretRedactionAndBounds() throws {
        let secret = "fixture-secret-123"
        let message = "Invalid tools: \(secret) csk-otherSecret Bearer another-secret\nAuthorization: basic hidden-secret"
        let bytes = try JSONSerialization.data(withJSONObject: ["error": ["code": "invalid_parameter_error", "type": "invalid_request_error", "param": "tools", "message": message], "id": "PRIVATE_RESPONSE_ID"])
        let body = event(String(decoding: bytes, as: UTF8.self))
        XCTAssertEqual(APIProviderHTTPClient.rejectedRequest(status: 400, body: body), .invalidTools)
        let report = APIProviderHTTPClient.rejectionDiagnostic(status: 400, body: body, modelID: "fixture", key: secret)
        let encoded = try JSONEncoder().encode(report), text = String(decoding: encoded, as: UTF8.self)
        XCTAssertEqual(report.envelope, "sse_wrapped_object")
        XCTAssertTrue(text.contains("[REDACTED]"))
        for forbidden in [secret, "csk-otherSecret", "another-secret", "hidden-secret", "Authorization", "PRIVATE_RESPONSE_ID", "data:"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertLessThanOrEqual(encoded.count, 7_168)
        let long = String(repeating: "🙂", count: 1_024)
        let longJSON = try JSONSerialization.data(withJSONObject: ["error": ["code": "unknown", "type": "unknown", "param": NSNull(), "message": long]])
        let bounded = APIProviderHTTPClient.rejectionDiagnostic(status: 422, body: event(String(decoding: longJSON, as: UTF8.self)), modelID: nil, key: "")
        XCTAssertEqual(bounded.error?.message?.utf8.count, 2_048)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(bounded).count, 7_168)
    }

    func testRateLimitSSEPreservesFiniteClassificationAndRejectsMixedFrames() throws {
        let object: [String: Any] = ["error": ["code": "overloaded", "type": "server_error", "message": "Busy", "param": NSNull()]]
        let json = try JSONSerialization.data(withJSONObject: object)
        let sse = event(String(decoding: json, as: UTF8.self))
        XCTAssertEqual(APIProviderHTTPClient.rateLimitFailure(body: json), .providerBusy)
        XCTAssertEqual(APIProviderHTTPClient.rateLimitFailure(body: sse), .providerBusy)
        XCTAssertEqual(APIProviderHTTPClient.rateLimitFailure(body: sse + sse), .rateLimited)
        XCTAssertEqual(APIProviderHTTPClient.rateLimitFailure(body: Data(repeating: 65, count: 16_385)), .rateLimited)
    }

    func testHTTPErrorNormalizesOnceWhileSuccessfulSSEBytesRemainUntouched() async throws {
        let body = event()
        ErrorSSEURLProtocol.reset(body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ErrorSSEURLProtocol.self]
        let client = APIProviderHTTPClient(configuration: configuration)
        let provider = APIProviderDefinition(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.invalid/v1")!, wireAPI: .chatCompletions, models: [])
        let capture = ErrorSSEURLProtocol.Capture()
        do {
            _ = try await client.request(provider: provider, key: "fixture-secret", path: "chat/completions", body: Data("{}".utf8), onRejection: { capture.save($0) })
            XCTFail("HTTP 400 must remain a failure")
        } catch { XCTAssertEqual(error as? APIProviderHTTPClient.Failure, .invalidMessages) }
        XCTAssertEqual(capture.value?.envelope, "sse_wrapped_object")
        XCTAssertEqual(capture.value?.error?.message, Self.roleMessage)
        XCTAssertEqual(ErrorSSEURLProtocol.requestCount, 1, "Classification cannot replay a rejected request")
        let successCapture = ErrorSSEURLProtocol.Capture()
        let success = try await client.request(provider: provider, key: "fixture-secret", path: "responses", body: Data("{}".utf8), onRejection: { successCapture.save($0) })
        XCTAssertEqual(success.body, body, "HTTP success must reach its existing decoder without this normalization")
        XCTAssertEqual(success.contentType, "text/event-stream")
        XCTAssertNil(successCapture.value)
        XCTAssertEqual(ErrorSSEURLProtocol.requestCount, 2)
    }
}

/// Every URL is intercepted locally; no provider/network access is possible.
private final class ErrorSSEURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var body = Data()
        private var count = 0
        func reset(_ value: Data) { lock.withLock { body = value; count = 0 } }
        func take() -> Data { lock.withLock { count += 1; return body } }
        var requests: Int { lock.withLock { count } }
    }
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var retained: APIProviderHTTPClient.RejectionDiagnostic?
        func save(_ value: APIProviderHTTPClient.RejectionDiagnostic) { lock.withLock { retained = value } }
        var value: APIProviderHTTPClient.RejectionDiagnostic? { lock.withLock { retained } }
    }
    private static let state = State()
    static func reset(_ body: Data) { state.reset(body) }
    static var requestCount: Int { state.requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "fixture.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let body = Self.state.take()
        let response = HTTPURLResponse(url: url, statusCode: url.lastPathComponent == "responses" ? 200 : 400,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream", "Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
